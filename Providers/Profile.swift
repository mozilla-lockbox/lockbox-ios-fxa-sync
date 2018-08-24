/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// IMPORTANT!: Please take into consideration when adding new imports to
// this file that it is utilized by external components besides the core
// application (i.e. App Extensions). Introducing new dependencies here
// may have unintended negative consequences for App Extensions such as
// increased startup times which may lead to termination by the OS.
import Account
import Shared
import Sync
import XCGLogger
import SwiftKeychainWrapper
import Deferred
import Storage
import SwiftyJSON


private let log = Logger.syncLogger

public let ProfileRemoteTabsSyncDelay: TimeInterval = 0.1

public protocol SyncManager {
    var isSyncing: Bool { get }
    var lastSyncFinishTime: Timestamp? { get set }
    var syncDisplayState: SyncDisplayState? { get }
//    func hasSyncedLogins() -> Deferred<Maybe<Bool>>

//    func syncClients() -> SyncResult
//    func syncClientsThenTabs() -> SyncResult
//    func syncHistory() -> SyncResult
    func syncLogins() -> SyncResult
//    func mirrorBookmarks() -> SyncResult
    @discardableResult func syncEverything(why: SyncReason) -> Success
    func syncNamedCollections(why: SyncReason, names: [String]) -> Success

    // The simplest possible approach.
    func beginTimedSyncs()
    func endTimedSyncs()
    func applicationDidEnterBackground()
    func applicationDidBecomeActive()

    func onNewProfile()
    @discardableResult func onRemovedAccount(_ account: FirefoxAccount?) -> Success
    @discardableResult func onAddedAccount() -> Success
}

typealias SyncFunction = (SyncDelegate, Prefs, Ready, SyncReason) -> SyncResult

class ProfileFileAccessor: FileAccessor {
    convenience init(profile: Profile) {
        self.init(localName: profile.localName())
    }

    init(localName: String) {
        let profileDirName = "profile.\(localName)"

        // Bug 1147262: First option is for device, second is for simulator.
        var rootPath: String
        let sharedContainerIdentifier = AppInfo.sharedContainerIdentifier
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier) {
            rootPath = url.path
        } else {
            log.error("Unable to find the shared container. Defaulting profile location to ~/Documents instead.")
            rootPath = (NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0])
        }

        super.init(rootPath: URL(fileURLWithPath: rootPath).appendingPathComponent(profileDirName).path)
    }
}

class CommandStoringSyncDelegate: SyncDelegate {
    let profile: Profile

    init(profile: Profile) {
        self.profile = profile
    }

    public func displaySentTab(for url: URL, title: String, from deviceName: String?) {
//        let item = ShareItem(url: url.absoluteString, title: title, favicon: nil)
//        _ = self.profile.queue.addToQueue(item)
    }
}

/**
 * A Profile manages access to the user's data.
 */
public protocol Profile: class {
//    var bookmarks: BookmarksModelFactorySource & KeywordSearchSource & ShareToDestination & SyncableBookmarks & LocalItemSource & MirrorItemSource { get }
    // var favicons: Favicons { get }
    var prefs: Prefs { get }
//    var queue: TabQueue { get }
//    var searchEngines: SearchEngines { get }
//    var files: FileAccessor { get }
//    var history: BrowserHistory & SyncableHistory & ResettableSyncStorage { get }
//    var metadata: Metadata { get }
//    var recommendations: HistoryRecommendations { get }
//    var favicons: Favicons { get }
    var logins: BrowserLogins & SyncableLogins & ResettableSyncStorage { get }
//    var certStore: CertStore { get }
//    var recentlyClosedTabs: ClosedTabsStore { get }
//    var panelDataObservers: PanelDataObservers { get }
//
//    #if !MOZ_TARGET_NOTIFICATIONSERVICE
//        var readingList: ReadingListService? { get }
//    #endif

    var isShutdown: Bool { get }
    
    func shutdown()
    func reopen()

    // I got really weird EXC_BAD_ACCESS errors on a non-null reference when I made this a getter.
    // Similar to <http://stackoverflow.com/questions/26029317/exc-bad-access-when-indirectly-accessing-inherited-member-in-swift>.
    func localName() -> String

    // URLs and account configuration.
    var accountConfiguration: FirefoxAccountConfiguration { get }

    // Do we have an account at all?
    func hasAccount() -> Bool

    // Do we have an account that (as far as we know) is in a syncable state?
    func hasSyncableAccount() -> Bool

    func getAccount() -> FirefoxAccount?
    func removeAccount() -> Success
    func setAccount(_ account: FirefoxAccount)
    func flushAccount()

//    func getClients() -> Deferred<Maybe<[RemoteClient]>>
//    func getClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>>
//    func getCachedClientsAndTabs() -> Deferred<Maybe<[ClientAndTabs]>>

//    @discardableResult func storeTabs(_ tabs: [RemoteTab]) -> Deferred<Maybe<Int>>
//
//    func sendItems(_ items: [ShareItem], toClients clients: [RemoteClient]) -> Deferred<Maybe<SyncStatus>>

    var syncManager: SyncManager! { get }
    var isChinaEdition: Bool { get }
}

fileprivate let PrefKeyClientID = "PrefKeyClientID"
extension Profile {
    var clientID: String {
        let clientID: String
        if let id = prefs.stringForKey(PrefKeyClientID) {
            clientID = id
        } else {
            clientID = UUID().uuidString
            prefs.setString(clientID, forKey: PrefKeyClientID)
        }
        return clientID
    }
}

public class BrowserProfile: Profile {
    fileprivate let name: String
    fileprivate let keychain: KeychainWrapper
    public var isShutdown = false

    internal let files: FileAccessor

    let loginsDB: BrowserDB
    public var syncManager: SyncManager!

    private static var loginsKey: String? {
        let key = "sqlcipher.key.logins.db"
        let keychain = KeychainWrapper.sharedAppContainerKeychain
        keychain.ensureStringItemAccessibility(.afterFirstUnlock, forKey: key)
        if keychain.hasValue(forKey: key) {
            return keychain.string(forKey: key)
        }

        let Length: UInt = 256
        let secret = Bytes.generateRandomBytes(Length).base64EncodedString
        keychain.set(secret, forKey: key, withAccessibility: .afterFirstUnlock)
        return secret
    }

    var syncDelegate: SyncDelegate?

    /**
     * N.B., BrowserProfile is used from our extensions, often via a pattern like
     *
     *   BrowserProfile(…).foo.saveSomething(…)
     *
     * This can break if BrowserProfile's initializer does async work that
     * subsequently — and asynchronously — expects the profile to stick around:
     * see Bug 1218833. Be sure to only perform synchronous actions here.
     *
     * A SyncDelegate can be provided in this initializer, or once the profile is initialized.
     * However, if we provide it here, it's assumed that we're initializing it from the application,
     * and initialize the logins.db.
     */
    public init(localName: String, syncDelegate: SyncDelegate? = nil, clear: Bool = false) {
        log.debug("Initing profile \(localName) on thread \(Thread.current).")
        self.name = localName
        self.files = ProfileFileAccessor(localName: localName)
        self.keychain = KeychainWrapper.sharedAppContainerKeychain
        self.syncDelegate = syncDelegate

        if clear {
            do {
                // Remove the contents of the directory…
                try self.files.removeFilesInDirectory()
                // …then remove the directory itself.
                try self.files.remove("")
            } catch {
                log.info("Cannot clear profile: \(error)")
            }
        }

        // If the profile dir doesn't exist yet, this is first run (for this profile). The check is made here
        // since the DB handles will create new DBs under the new profile folder.
        let isNewProfile = !files.exists("")

        // Set up our database handles.
        self.loginsDB = BrowserDB(filename: "logins.db", secretKey: BrowserProfile.loginsKey, schema: LoginsSchema(), files: files)

        // This has to happen prior to the databases being opened, because opening them can trigger
        // events to which the SyncManager listens.
        self.syncManager = BrowserSyncManager(profile: self)

        if isNewProfile {
            log.info("New profile. Removing old account metadata.")
            self.removeAccountMetadata()
            self.syncManager.onNewProfile()
            self.removeExistingAuthenticationInfo()
            prefs.clearAll()
        }

        // Always start by needing invalidation.
        // This is the same as self.history.setTopSitesNeedsInvalidation, but without the
        // side-effect of instantiating SQLiteHistory (and thus BrowserDB) on the main thread.
        prefs.setBool(false, forKey: PrefsKeys.KeyTopSitesCacheIsValid)

        if isChinaEdition {
            // Set the default homepage.
            prefs.setString(PrefsDefaults.ChineseHomePageURL, forKey: PrefsKeys.KeyDefaultHomePageURL)

            if prefs.stringForKey(PrefsKeys.KeyNewTab) == nil {
                prefs.setString(PrefsDefaults.ChineseNewTabDefault, forKey: PrefsKeys.KeyNewTab)
            }
        } else {
            // Remove the default homepage. This does not change the user's preference,
            // just the behaviour when there is no homepage.
            prefs.removeObjectForKey(PrefsKeys.KeyDefaultHomePageURL)
        }
    }

    public func reopen() {
        log.debug("Reopening profile.")
        isShutdown = false

        loginsDB.reopenIfClosed()
    }

    public func shutdown() {
        log.debug("Shutting down profile.")
        isShutdown = true

        loginsDB.forceClose()
    }

    deinit {
        log.debug("Deiniting profile \(self.localName).")
        self.syncManager.endTimedSyncs()
    }

    public func localName() -> String {
        return name
    }

    func makePrefs() -> Prefs {
        return NSUserDefaultsPrefs(prefix: self.localName())
    }

    public lazy var prefs: Prefs = {
        return self.makePrefs()
    }()

    open func getSyncDelegate() -> SyncDelegate {
        return syncDelegate ?? CommandStoringSyncDelegate(profile: self)
    }

    public lazy var logins: BrowserLogins & SyncableLogins & ResettableSyncStorage = {
        return SQLiteLogins(db: self.loginsDB)
    }()

    public lazy var isChinaEdition: Bool = {
        return Locale.current.identifier == "zh_CN"
    }()

    public var accountConfiguration: FirefoxAccountConfiguration {
        if prefs.boolForKey("useCustomSyncService") ?? false {
            return CustomFirefoxAccountConfiguration(prefs: self.prefs)
        }
        if prefs.boolForKey("useChinaSyncService") ?? isChinaEdition {
            return ChinaEditionFirefoxAccountConfiguration()
        }
        if prefs.boolForKey("useStageSyncService") ?? false {
            return StageFirefoxAccountConfiguration()
        }
        return ProductionFirefoxAccountConfiguration()
    }

    fileprivate lazy var account: FirefoxAccount? = {
        let key = self.name + ".account"
        self.keychain.ensureObjectItemAccessibility(.afterFirstUnlock, forKey: key)
        if let dictionary = self.keychain.object(forKey: key) as? [String: AnyObject] {
            let account =  FirefoxAccount.fromDictionary(dictionary)
            
            // Check to see if the account configuration set is a custom service
            // and update it to use the custom servers.
            if let configuration = account?.configuration as? CustomFirefoxAccountConfiguration {
                account?.configuration = CustomFirefoxAccountConfiguration(prefs: self.prefs)
            }
            
            return account
        }
        return nil
    }()

    public func hasAccount() -> Bool {
        return account != nil
    }

    public func hasSyncableAccount() -> Bool {
        return account?.actionNeeded == FxAActionNeeded.none
    }

    public func getAccount() -> FirefoxAccount? {
        return account
    }

    func removeAccountMetadata() {
        self.prefs.removeObjectForKey(PrefsKeys.KeyLastRemoteTabSyncTime)
        self.keychain.removeObject(forKey: self.name + ".account")
    }

    func removeExistingAuthenticationInfo() {
        self.keychain.setAuthenticationInfo(nil)
    }

    public func removeAccount() -> Success {
        let old = self.account
        removeAccountMetadata()
        self.account = nil

        // Tell any observers that our account has changed.
        NotificationCenter.default.post(name: .FirefoxAccountChanged, object: nil)

        // Trigger cleanup. Pass in the account in case we want to try to remove
        // client-specific data from the server.
        return self.syncManager.onRemovedAccount(old)
    }

    public func setAccount(_ account: FirefoxAccount) {
        self.account = account

        flushAccount()
        
        // tell any observers that our account has changed
        DispatchQueue.main.async {
            // Many of the observers for this notifications are on the main thread,
            // so we should post the notification there, just in case we're not already
            // on the main thread.
            let userInfo = [Notification.Name.UserInfoKeyHasSyncableAccount: self.hasSyncableAccount()]
            NotificationCenter.default.post(name: .FirefoxAccountChanged, object: nil, userInfo: userInfo)
        }

        self.syncManager.onAddedAccount()
    }

    public func flushAccount() {
        if let account = account {
            self.keychain.set(account.dictionary() as NSCoding, forKey: name + ".account", withAccessibility: .afterFirstUnlock)
        }
    }

    // Extends NSObject so we can use timers.
    public class BrowserSyncManager: NSObject, SyncManager, CollectionChangedNotifier {
        // We shouldn't live beyond our containing BrowserProfile, either in the main app or in
        // an extension.
        // But it's possible that we'll finish a side-effect sync after we've ditched the profile
        // as a whole, so we hold on to our Prefs, potentially for a little while longer. This is
        // safe as a strong reference, because there's no cycle.
        unowned fileprivate let profile: BrowserProfile
        fileprivate let prefs: Prefs

        let FifteenMinutes = TimeInterval(60 * 15)
        let OneMinute = TimeInterval(60)

        fileprivate var syncTimer: Timer?

        fileprivate var backgrounded: Bool = true
        public func applicationDidEnterBackground() {
            self.backgrounded = true
            self.endTimedSyncs()
        }

        public func applicationDidBecomeActive() {
            self.backgrounded = false

            guard self.profile.hasSyncableAccount() else {
                return
            }

            self.beginTimedSyncs()

            // Sync now if it's been more than our threshold.
            let now = Date.now()
            let then = self.lastSyncFinishTime ?? 0
            guard now >= then else {
                log.debug("Time was modified since last sync.")
                self.syncEverythingSoon()
                return
            }
            let since = now - then
            log.debug("\(since)msec since last sync.")
            if since > SyncConstants.SyncOnForegroundMinimumDelayMillis {
                self.syncEverythingSoon()
            }
        }

        /**
         * Locking is managed by syncSeveral. Make sure you take and release these
         * whenever you do anything Sync-ey.
         */
        fileprivate let syncLock = NSRecursiveLock()

        public var isSyncing: Bool {
            syncLock.lock()
            defer { syncLock.unlock() }
            return syncDisplayState != nil && syncDisplayState! == .inProgress
        }

        public var syncDisplayState: SyncDisplayState?

        // The dispatch queue for coordinating syncing and resetting the database.
        fileprivate let syncQueue = DispatchQueue(label: "com.mozilla.firefox.sync")

        fileprivate typealias EngineResults = [(EngineIdentifier, SyncStatus)]
        fileprivate typealias EngineTasks = [(EngineIdentifier, SyncFunction)]

        // Used as a task queue for syncing.
        fileprivate var syncReducer: AsyncReducer<EngineResults, EngineTasks>?

        fileprivate func beginSyncing() {
            notifySyncing(notification: .ProfileDidStartSyncing)
        }

        fileprivate func endSyncing(_ result: SyncOperationResult) {
            // loop through statuses and fill sync state
            syncLock.lock()
            defer { syncLock.unlock() }
            log.info("Ending all queued syncs.")

            syncDisplayState = SyncStatusResolver(engineResults: result.engineResults).resolveResults()

            #if MOZ_TARGET_CLIENT
                if let account = profile.account, canSendUsageData() {
                    SyncPing.from(result: result,
                                  account: account,
                                  remoteClientsAndTabs: profile.remoteClientsAndTabs,
                                  prefs: prefs,
                                  why: .schedule) >>== { SyncTelemetry.send(ping: $0, docType: .sync) }
                } else {
                    log.debug("Profile isn't sending usage data. Not sending sync status event.")
                }
            #endif

            // Dont notify if we are performing a sync in the background. This prevents more db access from happening
            if !self.backgrounded {
                notifySyncing(notification: .ProfileDidFinishSyncing)
            }
            syncReducer = nil
        }

        func canSendUsageData() -> Bool {
            return profile.prefs.boolForKey(AppConstants.PrefSendUsageData) ?? true
        }

        private func notifySyncing(notification: Notification.Name) {
            NotificationCenter.default.post(name: notification, object: syncDisplayState?.asObject())
        }

        init(profile: BrowserProfile) {
            self.profile = profile
            self.prefs = profile.prefs

            super.init()

            let center = NotificationCenter.default

            center.addObserver(self, selector: #selector(onDatabaseWasRecreated), name: .DatabaseWasRecreated, object: nil)
            center.addObserver(self, selector: #selector(onStartSyncing), name: .ProfileDidStartSyncing, object: nil)
            center.addObserver(self, selector: #selector(onFinishSyncing), name: .ProfileDidFinishSyncing, object: nil)
        }

        private func handleRecreationOfDatabaseNamed(name: String?) -> Success {
            let loginsCollections = ["passwords"]
            let browserCollections = ["bookmarks", "history", "tabs"]

            let dbName = name ?? "<all>"
            switch dbName {
            case "<all>":
                return self.locallyResetCollections(loginsCollections + browserCollections)
            case "logins.db":
                return self.locallyResetCollections(loginsCollections)
            case "browser.db":
                return self.locallyResetCollections(browserCollections)
            default:
                log.debug("Unknown database \(dbName).")
                return succeed()
            }
        }

        func doInBackgroundAfter(_ millis: Int64, _ block: @escaping () -> Void) {
            let queue = DispatchQueue.global(qos: DispatchQoS.background.qosClass)
            //Pretty ambiguous here. I'm thinking .now was DispatchTime.now() and not Date.now()
            queue.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(millis)), execute: block)
        }

        @objc
        func onDatabaseWasRecreated(notification: NSNotification) {
            log.debug("Database was recreated.")
            let name = notification.object as? String
            log.debug("Database was \(name ?? "nil").")

            // We run this in the background after a few hundred milliseconds;
            // it doesn't really matter when it runs, so long as it doesn't
            // happen in the middle of a sync.

            let resetDatabase = {
                return self.handleRecreationOfDatabaseNamed(name: name) >>== {
                    log.debug("Reset of \(name ?? "nil") done")
                }
            }

            self.doInBackgroundAfter(300) {
                self.syncLock.lock()
                defer { self.syncLock.unlock() }
                // If we're syncing already, then wait for sync to end,
                // then reset the database on the same serial queue.
                if let reducer = self.syncReducer, !reducer.isFilled {
                    reducer.terminal.upon { _ in
                        self.syncQueue.async(execute: resetDatabase)
                    }
                } else {
                    // Otherwise, reset the database on the sync queue now
                    // Sync can't start while this is still going on.
                    self.syncQueue.async(execute: resetDatabase)
                }
            }
        }

        // Simple in-memory rate limiting.
        var lastTriggeredLoginSync: Timestamp = 0
        @objc func onLoginDidChange(_ notification: NSNotification) {
            log.debug("Login did change.")
            if (Date.now() - lastTriggeredLoginSync) > OneMinuteInMilliseconds {
                lastTriggeredLoginSync = Date.now()

                // Give it a few seconds.
                // Trigger on the main queue. The bulk of the sync work runs in the background.
                let greenLight = self.greenLight()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(SyncConstants.SyncDelayTriggered)) {
                    if greenLight() {
                        self.syncLogins()
                    }
                }
            }
        }

        public var lastSyncFinishTime: Timestamp? {
            get {
                return self.prefs.timestampForKey(PrefsKeys.KeyLastSyncFinishTime)
            }

            set(value) {
                if let value = value {
                    self.prefs.setTimestamp(value, forKey: PrefsKeys.KeyLastSyncFinishTime)
                } else {
                    self.prefs.removeObjectForKey(PrefsKeys.KeyLastSyncFinishTime)
                }
            }
        }

        @objc func onStartSyncing(_ notification: NSNotification) {
            syncLock.lock()
            defer { syncLock.unlock() }
            syncDisplayState = .inProgress
        }

        @objc func onFinishSyncing(_ notification: NSNotification) {
            syncLock.lock()
            defer { syncLock.unlock() }
            if let syncState = syncDisplayState, syncState == .good {
                self.lastSyncFinishTime = Date.now()
            }
        }

        var prefsForSync: Prefs {
            return self.prefs.branch("sync")
        }

        public func onAddedAccount() -> Success {
            // Only sync if we're green lit. This makes sure that we don't sync unverified accounts.
            guard self.profile.hasSyncableAccount() else { return succeed() }

            self.beginTimedSyncs()
            return self.syncEverything(why: .didLogin)
        }

        func locallyResetCollections(_ collections: [String]) -> Success {
            return walk(collections, f: self.locallyResetCollection)
        }

        func locallyResetCollection(_ collection: String) -> Success {
            switch collection {
            case "passwords":
                return LoginsSynchronizer.resetSynchronizerWithStorage(self.profile.logins, basePrefs: self.prefsForSync, collection: "passwords")
            default:
                log.warning("Asked to reset collection \(collection), which we don't know about.")
                return succeed()
            }
        }

        public func onNewProfile() {
            SyncStateMachine.clearStateFromPrefs(self.prefsForSync)
        }

        public func onRemovedAccount(_ account: FirefoxAccount?) -> Success {
            let profile = self.profile

            // Run these in order, because they might write to the same DB!
            let remove = [
                profile.logins.onRemovedAccount,
            ]

            let clearPrefs: () -> Success = {
                withExtendedLifetime(self) {
                    // Clear prefs after we're done clearing everything else -- just in case
                    // one of them needs the prefs and we race. Clear regardless of success
                    // or failure.

                    // This will remove keys from the Keychain if they exist, as well
                    // as wiping the Sync prefs.
                    SyncStateMachine.clearStateFromPrefs(self.prefsForSync)
                }
                return succeed()
            }

            return accumulate(remove) >>> clearPrefs
        }

        fileprivate func repeatingTimerAtInterval(_ interval: TimeInterval, selector: Selector) -> Timer {
            return Timer.scheduledTimer(timeInterval: interval, target: self, selector: selector, userInfo: nil, repeats: true)
        }

        public func beginTimedSyncs() {
            if self.syncTimer != nil {
                log.debug("Already running sync timer.")
                return
            }

            let interval = FifteenMinutes
            let selector = #selector(syncOnTimer)
            log.debug("Starting sync timer.")
            self.syncTimer = repeatingTimerAtInterval(interval, selector: selector)
        }

        /**
         * The caller is responsible for calling this on the same thread on which it called
         * beginTimedSyncs.
         */
        public func endTimedSyncs() {
            if let t = self.syncTimer {
                log.debug("Stopping sync timer.")
                self.syncTimer = nil
                t.invalidate()
            }
        }

        fileprivate func syncLoginsWithDelegate(_ delegate: SyncDelegate, prefs: Prefs, ready: Ready, why: SyncReason) -> SyncResult {
            log.debug("Syncing logins to storage.")
            let loginsSynchronizer = ready.synchronizer(LoginsSynchronizer.self, delegate: delegate, prefs: prefs, why: why)
            return loginsSynchronizer.synchronizeLocalLogins(self.profile.logins, withServer: ready.client, info: ready.info)
        }

        func takeActionsOnEngineStateChanges<T: EngineStateChanges>(_ changes: T) -> Deferred<Maybe<T>> {
            var needReset = Set<String>(changes.collectionsThatNeedLocalReset())
            needReset.formUnion(changes.enginesDisabled())
            needReset.formUnion(changes.enginesEnabled())
            if needReset.isEmpty {
                log.debug("No collections need reset. Moving on.")
                return deferMaybe(changes)
            }

            // needReset needs at most one of clients and tabs, because we reset them
            // both if either needs reset. This is strictly an optimization to avoid
            // doing duplicate work.
            if needReset.contains("clients") {
                if needReset.remove("tabs") != nil {
                    log.debug("Already resetting clients (and tabs); not bothering to also reset tabs again.")
                }
            }

            return walk(Array(needReset), f: self.locallyResetCollection)
               >>> effect(changes.clearLocalCommands)
               >>> always(changes)
        }

        /**
         * Runs the single provided synchronization function and returns its status.
         */
        fileprivate func sync(_ label: EngineIdentifier, function: @escaping SyncFunction) -> SyncResult {
            return syncSeveral(why: .user, synchronizers: [(label, function)]) >>== { statuses in
                let status = statuses.find { label == $0.0 }?.1
                return deferMaybe(status ?? .notStarted(.unknown))
            }
        }

        /**
         * Convenience method for syncSeveral([(EngineIdentifier, SyncFunction)])
         */
        private func syncSeveral(why: SyncReason, synchronizers: (EngineIdentifier, SyncFunction)...) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            return syncSeveral(why: why, synchronizers: synchronizers)
        }

        /**
         * Runs each of the provided synchronization functions with the same inputs.
         * Returns an array of IDs and SyncStatuses at least length as the input.
         * The statuses returned will be a superset of the ones that are requested here.
         * While a sync is ongoing, each engine from successive calls to this method will only be called once.
         */
        fileprivate func syncSeveral(why: SyncReason, synchronizers: [(EngineIdentifier, SyncFunction)]) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            syncLock.lock()
            defer { syncLock.unlock() }

            guard let account = self.profile.account else {
                log.info("No account to sync with.")
                let statuses = synchronizers.map {
                    ($0.0, SyncStatus.notStarted(.noAccount))
                }
                return deferMaybe(statuses)
            }

            if !isSyncing {
                // A sync isn't already going on, so start another one.
                let statsSession = SyncOperationStatsSession(why: why, uid: account.uid, deviceID: account.deviceRegistration?.id)
                let reducer = AsyncReducer<EngineResults, EngineTasks>(initialValue: [], queue: syncQueue) { (statuses, synchronizers)  in
                    let done = Set(statuses.map { $0.0 })
                    let remaining = synchronizers.filter { !done.contains($0.0) }
                    if remaining.isEmpty {
                        log.info("Nothing left to sync")
                        return deferMaybe(statuses)
                    }

                    return self.syncWith(synchronizers: remaining, account: account, statsSession: statsSession, why: why) >>== { deferMaybe(statuses + $0) }
                }

                reducer.terminal.upon { results in
                    let result = SyncOperationResult(
                        engineResults: results,
                        stats: statsSession.hasStarted() ? statsSession.end() : nil
                    )
                    self.endSyncing(result)
                }

                // The actual work of synchronizing doesn't start until we append
                // the synchronizers to the reducer below.
                self.syncReducer = reducer
                self.beginSyncing()
                
                do {
                    return try reducer.append(synchronizers)
                } catch let error {
                    log.error("Synchronizers appended after sync was finished. This is a bug. \(error)")
                    let statuses = synchronizers.map {
                        ($0.0, SyncStatus.notStarted(.unknown))
                    }
                    return deferMaybe(statuses)
                }
            }
        }

        func engineEnablementChangesForAccount(account: FirefoxAccount, profile: Profile) -> [String: Bool]? {
            var enginesEnablements: [String: Bool] = [:]
            // We just created the account, the user went through the Choose What to Sync screen on FxA.
            if let declined = account.declinedEngines {
                declined.forEach { enginesEnablements[$0] = false }
                account.declinedEngines = nil
                // Persist account changes so we don't try to decline engines on the next sync.
                profile.flushAccount()
            } else {
                // Bundle in authState the engines the user activated/disabled since the last sync.
                TogglableEngines.forEach { engine in
                    let stateChangedPref = "engine.\(engine).enabledStateChanged"
                    if let _ = self.prefsForSync.boolForKey(stateChangedPref),
                        let enabled = self.prefsForSync.boolForKey("engine.\(engine).enabled") {
                        enginesEnablements[engine] = enabled
                        self.prefsForSync.setObject(nil, forKey: stateChangedPref)
                    }
                }
            }
            return enginesEnablements
        }

        // This SHOULD NOT be called directly: use syncSeveral instead.
        fileprivate func syncWith(synchronizers: [(EngineIdentifier, SyncFunction)],
                                  account: FirefoxAccount,
                                  statsSession: SyncOperationStatsSession, why: SyncReason) -> Deferred<Maybe<[(EngineIdentifier, SyncStatus)]>> {
            log.info("Syncing \(synchronizers.map { $0.0 })")
            var authState = account.syncAuthState
            let delegate = self.profile.getSyncDelegate()
            if let enginesEnablements = self.engineEnablementChangesForAccount(account: account, profile: profile),
               !enginesEnablements.isEmpty {
                authState?.enginesEnablements = enginesEnablements
                log.debug("engines to enable: \(enginesEnablements.flatMap { $0.value ? $0.key : nil })")
                log.debug("engines to disable: \(enginesEnablements.flatMap { !$0.value ? $0.key : nil })")
            }

            authState?.clientName = account.deviceName

            let readyDeferred = SyncStateMachine(prefs: self.prefsForSync).toReady(authState!)

            let function: (SyncDelegate, Prefs, Ready) -> Deferred<Maybe<[EngineStatus]>> = { delegate, syncPrefs, ready in
                let thunks = synchronizers.map { (i, f) in
                    return { () -> Deferred<Maybe<EngineStatus>> in
                        log.debug("Syncing \(i)…")
                        return f(delegate, syncPrefs, ready, why) >>== { deferMaybe((i, $0)) }
                    }
                }
                return accumulate(thunks)
            }
            
            return readyDeferred >>== self.takeActionsOnEngineStateChanges >>== { ready in
                let updateEnginePref: ((String, Bool) -> Void) = { engine, enabled in
                    self.prefsForSync.setBool(enabled, forKey: "engine.\(engine).enabled")
                }
                ready.engineConfiguration?.enabled.forEach { updateEnginePref($0, true) }
                ready.engineConfiguration?.declined.forEach { updateEnginePref($0, false) }

                statsSession.start()
                return function(delegate, self.prefsForSync, ready)
            }
        }

        @discardableResult public func syncEverything(why: SyncReason) -> Success {
            return self.syncSeveral(
                why: why,
                synchronizers:
                ("logins", self.syncLoginsWithDelegate)
                ) >>> succeed
        }

        func syncEverythingSoon() {
            self.doInBackgroundAfter(SyncConstants.SyncOnForegroundAfterMillis) {
                log.debug("Running delayed startup sync.")
                sleep(15)
                self.syncEverything(why: .startup)
            }
        }

        /**
         * Allows selective sync of different collections, for use by external APIs.
         * Some help is given to callers who use different namespaces (specifically: `passwords` is mapped to `logins`)
         * and to preserve some ordering rules.
         */
        public func syncNamedCollections(why: SyncReason, names: [String]) -> Success {
            // Massage the list of names into engine identifiers.
            let engineIdentifiers = names.map { name -> [EngineIdentifier] in
                switch name {
                case "passwords":
                    return ["logins"]
                case "tabs":
                    return ["clients", "tabs"]
                default:
                    return [name]
                }
            }.flatMap { $0 }

            // By this time, `engineIdentifiers` may have duplicates in. We won't try and dedupe here
            // because `syncSeveral` will do that for us.

            let synchronizers: [(EngineIdentifier, SyncFunction)] = engineIdentifiers.flatMap {
                switch $0 {
//                case "clients": return ("clients", self.syncClientsWithDelegate)
//                case "tabs": return ("tabs", self.syncTabsWithDelegate)
                case "logins": return ("logins", self.syncLoginsWithDelegate)
//                case "bookmarks": return ("bookmarks", self.mirrorBookmarksWithDelegate)
//                case "history": return ("history", self.syncHistoryWithDelegate)
                default: return nil
                }
            }
            return self.syncSeveral(why: why, synchronizers: synchronizers) >>> succeed
        }

        @objc func syncOnTimer() {
            self.syncEverything(why: .scheduled)
        }

        public func hasSyncedLogins() -> Deferred<Maybe<Bool>> {
            return self.profile.logins.hasSyncedLogins()
        }

        @discardableResult public func syncLogins() -> SyncResult {
            return self.sync("logins", function: syncLoginsWithDelegate)
        }

        /**
         * Return a thunk that continues to return true so long as an ongoing sync
         * should continue.
         */
        func greenLight() -> () -> Bool {
            let start = Date.now()

            // Give it two minutes to run before we stop.
            let stopBy = start + (2 * OneMinuteInMilliseconds)
            log.debug("Checking green light. Backgrounded: \(self.backgrounded).")
            return {
                Date.now() < stopBy &&
                self.profile.hasSyncableAccount()
            }
        }

        class NoAccountError: MaybeErrorType {
            var description = "No account."
        }

        public func notify(deviceIDs: [GUID], collectionsChanged collections: [String], reason: String) -> Success {
            guard let account = self.profile.account else {
                return deferMaybe(NoAccountError())
            }
            return account.notify(deviceIDs: deviceIDs, collectionsChanged: collections, reason: reason)
        }

        public func notifyAll(collectionsChanged collections: [String], reason: String) -> Success {
            guard let account = self.profile.account else {
                return deferMaybe(NoAccountError())
            }
            return account.notifyAll(collectionsChanged: collections, reason: reason)
        }
    }
}

public struct SyncConstants {
    // Suitable for use in dispatch_time().
    public static let SyncDelayTriggered: Int = 3000
    public static let SyncOnForegroundMinimumDelayMillis: UInt64 = 5 * 60 * 1000
    public static let SyncOnForegroundAfterMillis: Int64 = 5000
}
