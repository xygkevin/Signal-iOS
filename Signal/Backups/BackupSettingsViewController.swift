//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SignalServiceKit
import SignalUI
import StoreKit
import SwiftUI

class BackupSettingsViewController: HostingController<BackupSettingsView> {
    enum OnLoadAction {
        case none
        case presentWelcomeToBackupsSheet
    }

    private let accountKeyStore: AccountKeyStore
    private let backupAttachmentDownloadTracker: BackupSettingsAttachmentDownloadTracker
    private let backupAttachmentUploadTracker: BackupSettingsAttachmentUploadTracker
    private let backupDisablingManager: BackupDisablingManager
    private let backupEnablingManager: BackupEnablingManager
    private let backupExportJob: BackupExportJob
    private let backupPlanManager: BackupPlanManager
    private let backupSettingsStore: BackupSettingsStore
    private let backupSubscriptionManager: BackupSubscriptionManager
    private let db: DB

    private var eventObservationTasks: [Task<Void, Never>]
    private let onLoadAction: OnLoadAction
    private let viewModel: BackupSettingsViewModel

    convenience init(
        onLoadAction: OnLoadAction,
    ) {
        self.init(
            onLoadAction: onLoadAction,
            accountKeyStore: DependenciesBridge.shared.accountKeyStore,
            backupAttachmentDownloadProgress: DependenciesBridge.shared.backupAttachmentDownloadProgress,
            backupAttachmentDownloadQueueStatusReporter: DependenciesBridge.shared.backupAttachmentDownloadQueueStatusReporter,
            backupAttachmentUploadProgress: DependenciesBridge.shared.backupAttachmentUploadProgress,
            backupAttachmentUploadQueueStatusReporter: DependenciesBridge.shared.backupAttachmentUploadQueueStatusReporter,
            backupDisablingManager: AppEnvironment.shared.backupDisablingManager,
            backupEnablingManager: AppEnvironment.shared.backupEnablingManager,
            backupExportJob: DependenciesBridge.shared.backupExportJob,
            backupPlanManager: DependenciesBridge.shared.backupPlanManager,
            backupSettingsStore: BackupSettingsStore(),
            backupSubscriptionManager: DependenciesBridge.shared.backupSubscriptionManager,
            db: DependenciesBridge.shared.db,
            tsAccountManager: DependenciesBridge.shared.tsAccountManager,
        )
    }

    init(
        onLoadAction: OnLoadAction,
        accountKeyStore: AccountKeyStore,
        backupAttachmentDownloadProgress: BackupAttachmentDownloadProgress,
        backupAttachmentDownloadQueueStatusReporter: BackupAttachmentDownloadQueueStatusReporter,
        backupAttachmentUploadProgress: BackupAttachmentUploadProgress,
        backupAttachmentUploadQueueStatusReporter: BackupAttachmentUploadQueueStatusReporter,
        backupDisablingManager: BackupDisablingManager,
        backupEnablingManager: BackupEnablingManager,
        backupExportJob: BackupExportJob,
        backupPlanManager: BackupPlanManager,
        backupSettingsStore: BackupSettingsStore,
        backupSubscriptionManager: BackupSubscriptionManager,
        db: DB,
        tsAccountManager: TSAccountManager
    ) {
        owsPrecondition(
            db.read { tsAccountManager.registrationState(tx: $0).isPrimaryDevice == true },
            "Unsafe to let a linked device access Backup Settings!"
        )

        self.accountKeyStore = accountKeyStore
        self.backupAttachmentDownloadTracker = BackupSettingsAttachmentDownloadTracker(
            backupAttachmentDownloadQueueStatusReporter: backupAttachmentDownloadQueueStatusReporter,
            backupAttachmentDownloadProgress: backupAttachmentDownloadProgress
        )
        self.backupAttachmentUploadTracker = BackupSettingsAttachmentUploadTracker(
            backupAttachmentUploadQueueStatusReporter: backupAttachmentUploadQueueStatusReporter,
            backupAttachmentUploadProgress: backupAttachmentUploadProgress
        )
        self.backupDisablingManager = backupDisablingManager
        self.backupEnablingManager = backupEnablingManager
        self.backupExportJob = backupExportJob
        self.backupPlanManager = backupPlanManager
        self.backupSettingsStore = backupSettingsStore
        self.backupSubscriptionManager = backupSubscriptionManager
        self.db = db

        self.eventObservationTasks = []
        self.onLoadAction = onLoadAction
        self.viewModel = db.read { tx in
            let viewModel = BackupSettingsViewModel(
                backupEnabledState: .disabled, // Default, set below
                backupSubscriptionLoadingState: .loading, // Default, loaded after init
                backupPlan: backupPlanManager.backupPlan(tx: tx),
                latestBackupAttachmentDownloadUpdate: nil, // Default, loaded after init
                latestBackupAttachmentUploadUpdate: nil, // Default, loaded after init
                lastBackupDate: backupSettingsStore.lastBackupDate(tx: tx),
                lastBackupSizeBytes: backupSettingsStore.lastBackupSizeBytes(tx: tx),
                shouldAllowBackupUploadsOnCellular: backupSettingsStore.shouldAllowBackupUploadsOnCellular(tx: tx)
            )

            if let disableBackupsRemotelyState = backupDisablingManager.currentDisableRemotelyState(tx: tx) {
                viewModel.handleDisableBackupsRemoteState(disableBackupsRemotelyState)
            } else {
                switch backupPlanManager.backupPlan(tx: tx) {
                case .disabled:
                    viewModel.backupEnabledState = .disabled
                case .free, .paid, .paidExpiringSoon:
                    viewModel.backupEnabledState = .enabled
                }
            }

            return viewModel
        }

        super.init(wrappedView: BackupSettingsView(viewModel: viewModel))

        title = OWSLocalizedString(
            "BACKUPS_SETTINGS_TITLE",
            comment: "Title for the 'Backup' settings menu."
        )
        OWSTableViewController2.removeBackButtonText(viewController: self)

        viewModel.actionsDelegate = self
        // Run as soon as we've set the actionDelegate.
        viewModel.loadBackupSubscription()

        eventObservationTasks = [
            Task { [weak self, backupAttachmentDownloadTracker] in
                for await downloadUpdate in backupAttachmentDownloadTracker.updates() {
                    guard let self else { return }
                    viewModel.latestBackupAttachmentDownloadUpdate = downloadUpdate
                }
            },
            Task { [weak self, backupAttachmentUploadTracker] in
                for await uploadUpdate in backupAttachmentUploadTracker.updates() {
                    guard let self else { return }
                    viewModel.latestBackupAttachmentUploadUpdate = uploadUpdate
                }
            },
            Task.detached { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .backupPlanChanged
                ) {
                    await MainActor.run { [weak self] in
                        guard let self else { return }

                        db.read { tx in
                            self.viewModel.backupPlan = backupPlanManager.backupPlan(tx: tx)
                        }
                        viewModel.loadBackupSubscription()
                    }
                }
            },
        ]
    }

    deinit {
        eventObservationTasks.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        switch onLoadAction {
        case .none:
            break
        case .presentWelcomeToBackupsSheet:
            presentWelcomeToBackupsSheet()
        }
    }
}

// MARK: - BackupSettingsViewModel.ActionsDelegate

extension BackupSettingsViewController: BackupSettingsViewModel.ActionsDelegate {
    fileprivate func enableBackups(
        implicitPlanSelection: ChooseBackupPlanViewController.PlanSelection?
    ) {
        // TODO: [Backups] Show the rest of the onboarding flow.

        Task {
            if let planSelection = implicitPlanSelection {
                await _enableBackups(
                    fromViewController: self,
                    planSelection: planSelection
                )
            } else {
                await showChooseBackupPlan(initialPlanSelection: nil)
            }
        }
    }

    @MainActor
    private func showChooseBackupPlan(
        initialPlanSelection: ChooseBackupPlanViewController.PlanSelection?
    ) async {
        let chooseBackupPlanViewController: ChooseBackupPlanViewController
        do throws(OWSAssertionError) {
            chooseBackupPlanViewController = try await .load(
                fromViewController: self,
                initialPlanSelection: initialPlanSelection,
                onConfirmPlanSelectionBlock: { [weak self] chooseBackupPlanViewController, planSelection in
                    Task { [weak self] in
                        guard let self else { return }

                        await _enableBackups(
                            fromViewController: chooseBackupPlanViewController,
                            planSelection: planSelection
                        )
                    }
                }
            )
        } catch {
            return
        }

        navigationController?.pushViewController(
            chooseBackupPlanViewController,
            animated: true
        )
    }

    @MainActor
    private func _enableBackups(
        fromViewController: UIViewController,
        planSelection: ChooseBackupPlanViewController.PlanSelection
    ) async {
        do throws(BackupEnablingManager.DisplayableError) {
            try await backupEnablingManager.enableBackups(
                fromViewController: fromViewController,
                planSelection: planSelection
            )
        } catch {
            OWSActionSheets.showActionSheet(
                message: error.localizedActionSheetMessage,
                fromViewController: fromViewController,
            )
            return
        }

        // We know we're enabled now! Set state before popping so correct UI is shown.
        viewModel.backupEnabledState = .enabled
        navigationController?.popToViewController(self, animated: true) { [self] in
            presentWelcomeToBackupsSheet()
        }
    }

    private func presentWelcomeToBackupsSheet() {
        let welcomeToBackupsSheet = HeroSheetViewController(
            hero: .image(.backupsSubscribed),
            title: OWSLocalizedString(
                "BACKUP_SETTINGS_WELCOME_TO_BACKUPS_SHEET_TITLE",
                comment: "Title for a sheet shown after the user enables backups."
            ),
            body: OWSLocalizedString(
                "BACKUP_SETTINGS_WELCOME_TO_BACKUPS_SHEET_MESSAGE",
                comment: "Message for a sheet shown after the user enables backups."
            ),
            primary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "BACKUP_SETTINGS_WELCOME_TO_BACKUPS_SHEET_PRIMARY_BUTTON",
                    comment: "Title for the primary button for a sheet shown after the user enables backups."
                ),
                action: { _ in
                    self.viewModel.performManualBackup()
                }
            )),
            secondary: .button(.dismissing(
                title: OWSLocalizedString(
                    "BACKUP_SETTINGS_WELCOME_TO_BACKUPS_SHEET_SECONDARY_BUTTON",
                    comment: "Title for the secondary button for a sheet shown after the user enables backups."
                ),
                style: .secondary
            ))
        )

        present(welcomeToBackupsSheet, animated: true)
    }

    // MARK: -

    fileprivate func disableBackups() {
        Task { await _disableBackups() }
    }

    @MainActor
    private func _disableBackups() async {
        do {
            try await backupDisablingManager.startDisablingBackups()

            if let disableRemotelyState = db.read(block: { backupDisablingManager.currentDisableRemotelyState(tx: $0) }) {
                viewModel.handleDisableBackupsRemoteState(disableRemotelyState)
            }
        } catch is BackupDisablingManager.NotRegisteredError {
            OWSActionSheets.showActionSheet(
                message: OWSLocalizedString(
                    "BACKUP_SETTINGS_DISABLING_ERROR_NOT_REGISTERED",
                    comment: "Message shown in an action sheet when the user tries to disable Backups, but is not registered."
                ),
                fromViewController: self
            )
        } catch {
            showDisablingBackupsFailedSheet()
        }
    }

    func showDisablingBackupsFailedSheet() {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "BACKUP_SETTINGS_DISABLING_ERROR_GENERIC_ERROR_ACTION_SHEET_TITLE",
                comment: "Title shown in an action sheet indicating we failed to delete the user's Backup due to an unexpected error."
            ),
            message: OWSLocalizedString(
                "BACKUP_SETTINGS_DISABLING_ERROR_GENERIC_ERROR_ACTION_SHEET_MESSAGE",
                comment: "Message shown in an action sheet indicating we failed to delete the user's Backup due to an unexpected error."
            ),
        )
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.contactSupport) { _ in
            ContactSupportActionSheet.present(
                emailFilter: .custom("iOS Disable Backups Failed"),
                logDumper: .fromGlobals(),
                fromViewController: self
            )
        })
        actionSheet.addAction(.okay)

        OWSActionSheets.showActionSheet(actionSheet, fromViewController: self)
    }

    // MARK: -

    fileprivate func loadBackupSubscription() async throws -> BackupSettingsViewModel.BackupSubscriptionLoadingState.LoadedBackupSubscription {
        var currentBackupPlan = db.read { backupPlanManager.backupPlan(tx: $0) }

        switch currentBackupPlan {
        case .free:
            return .free
        case .disabled, .paid, .paidExpiringSoon:
            break
        }

        guard
            let backupSubscription = try await backupSubscriptionManager
                .fetchAndMaybeDowngradeSubscription()
        else {
            return .free
        }

        // The subscription fetch may have updated our local Backup plan.
        currentBackupPlan = db.read { backupPlanManager.backupPlan(tx: $0) }

        switch currentBackupPlan {
        case .free:
            return .free
        case .disabled, .paid, .paidExpiringSoon:
            break
        }

        let endOfCurrentPeriod = Date(timeIntervalSince1970: backupSubscription.endOfCurrentPeriod)

        if backupSubscription.cancelAtEndOfPeriod {
            if endOfCurrentPeriod.isAfterNow {
                return .paidButExpiring(expirationDate: endOfCurrentPeriod)
            } else {
                return .paidButExpired(expirationDate: endOfCurrentPeriod)
            }
        }

        return .paid(
            price: backupSubscription.amount,
            renewalDate: endOfCurrentPeriod
        )
    }

    // MARK: -

    fileprivate func upgradeFromFreeToPaidPlan() {
        Task {
            await showChooseBackupPlan(initialPlanSelection: .free)
        }
    }

    fileprivate func manageOrCancelPaidPlan() {
        guard let windowScene = view.window?.windowScene else {
            owsFailDebug("Missing window scene!")
            return
        }

        Task {
            do {
                try await AppStore.showManageSubscriptions(in: windowScene)
            } catch {
                owsFailDebug("Failed to show manage-subscriptions view! \(error)")
            }

            // Reload the BackupPlan, since our subscription may now be in a
            // different state (e.g., set to not renew).
            viewModel.loadBackupSubscription()
        }
    }

    // MARK: -

    fileprivate func performManualBackup() {
        // TODO: [Backups] Implement nicer UI
        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            asyncBlock: { [weak self, backupExportJob] modal in
                do {
                    try await backupExportJob.exportAndUploadBackup(progress: nil)
                    guard let self else { return }
                    self.db.read { tx in
                        self.viewModel.lastBackupDate = self.backupSettingsStore.lastBackupDate(tx: tx)
                        self.viewModel.lastBackupSizeBytes = self.backupSettingsStore.lastBackupSizeBytes(tx: tx)
                    }
                } catch {
                    owsFailDebug("Unable to create backup!")
                }
                modal.dismiss()
            }
        )
    }

    fileprivate func setShouldAllowBackupUploadsOnCellular(_ newShouldAllowBackupUploadsOnCellular: Bool) {
        db.write { tx in
            backupSettingsStore.setShouldAllowBackupUploadsOnCellular(newShouldAllowBackupUploadsOnCellular, tx: tx)
        }
    }

    // MARK: -

    fileprivate func setOptimizeLocalStorage(_ newOptimizeLocalStorage: Bool) {
        do {
            try db.writeWithRollbackIfThrows { tx in
                let currentBackupPlan = backupPlanManager.backupPlan(tx: tx)
                let newBackupPlan: BackupPlan

                switch currentBackupPlan {
                case .disabled, .free:
                    owsFailDebug("Shouldn't be setting Optimize Local Storage: \(currentBackupPlan)")
                    return
                case .paid:
                    newBackupPlan = .paid(optimizeLocalStorage: newOptimizeLocalStorage)
                case .paidExpiringSoon:
                    newBackupPlan = .paidExpiringSoon(optimizeLocalStorage: newOptimizeLocalStorage)
                }

                try backupPlanManager.setBackupPlan(newBackupPlan, tx: tx)
            }
        } catch {
            owsFailDebug("Failed to set Optimize Local Storage: \(error)")
            return
        }

        // If disabling Optimize Local Storage, offer to start downloads now.
        if !newOptimizeLocalStorage {
            showDownloadOffloadedMediaSheet()
        }
    }

    private func showDownloadOffloadedMediaSheet() {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_DOWNLOAD_SHEET_TITLE",
                comment: "Title for an action sheet allowing users to download their offloaded media."
            ),
            message: OWSLocalizedString(
                "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_DOWNLOAD_SHEET_MESSAGE",
                comment: "Message for an action sheet allowing users to download their offloaded media."
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_DOWNLOAD_SHEET_NOW_ACTION",
                comment: "Action in an action sheet allowing users to download their offloaded media now."
            ),
            handler: { [weak self] _ in
                guard let self else { return }

                db.write { tx in
                    self.backupSettingsStore.setIsBackupDownloadQueueSuspended(false, tx: tx)
                }
            }
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_DOWNLOAD_SHEET_LATER_ACTION",
                comment: "Action in an action sheet allowing users to download their offloaded media later."
            ),
            handler: { _ in }
        ))

        presentActionSheet(actionSheet)
    }

    // MARK: -

    fileprivate func setIsBackupDownloadQueueSuspended(_ isSuspended: Bool, backupPlan: BackupPlan) {
        if isSuspended {
            switch backupPlan {
            case .disabled, .free, .paid:
                db.write { tx in
                    backupSettingsStore.setIsBackupDownloadQueueSuspended(true, tx: tx)
                }
            case .paidExpiringSoon:
                let warningSheet = ActionSheetController(
                    title: OWSLocalizedString(
                        "BACKUP_SETTINGS_SKIP_DOWNLOADS_WARNING_SHEET_TITLE",
                        comment: "Title for a sheet warning the user about skipping downloads.",
                    ),
                    message: OWSLocalizedString(
                        "BACKUP_SETTINGS_SKIP_DOWNLOADS_WARNING_SHEET_MESSAGE",
                        comment: "Message for a sheet warning the user about skipping downloads.",
                    )
                )
                warningSheet.addAction(ActionSheetAction(
                    title: OWSLocalizedString(
                        "BACKUP_SETTINGS_SKIP_DOWNLOADS_WARNING_SHEET_ACTION_SKIP",
                        comment: "Title for an action in a sheet warning the user about skipping downloads.",
                    ),
                    style: .destructive,
                    handler: { [self] _ in
                        db.write { tx in
                            backupSettingsStore.setIsBackupDownloadQueueSuspended(true, tx: tx)
                        }
                    }
                ))
                warningSheet.addAction(ActionSheetAction(
                    title: CommonStrings.learnMore,
                    handler: { _ in
                        CurrentAppContext().open(
                            URL(string: "https://support.signal.org/hc/articles/360007059752")!,
                            completion: nil
                        )
                    }
                ))
                warningSheet.addAction(.cancel)

                presentActionSheet(warningSheet)
            }
        } else {
            db.write { tx in
                backupSettingsStore.setIsBackupDownloadQueueSuspended(false, tx: tx)
            }
        }
    }

    fileprivate func setShouldAllowBackupDownloadsOnCellular() {
        db.write { tx in
            backupSettingsStore.setShouldAllowBackupDownloadsOnCellular(tx: tx)
        }
    }

    // MARK: -

    fileprivate func showViewBackupKey() {
        Task { await _showViewBackupKey() }
    }

    @MainActor
    private func _showViewBackupKey() async {
        guard let aep = db.read(block: { accountKeyStore.getAccountEntropyPool(tx: $0) }) else {
            return
        }

        guard await LocalDeviceAuthentication().performBiometricAuth() else {
            return
        }

        navigationController?.pushViewController(
            BackupRecordKeyViewController(
                aep: aep,
                isOnboardingFlow: false,
                onCompletion: { [weak self] recordKeyViewController in
                    self?.showKeyRecordedConfirmationSheet(
                        fromViewController: recordKeyViewController
                    )
                }
            ),
            animated: true
        )
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    private func showKeyRecordedConfirmationSheet(fromViewController: BackupRecordKeyViewController) {
        let sheet = HeroSheetViewController(
            hero: .image(.backupsKey),
            title: OWSLocalizedString(
                "BACKUP_ONBOARDING_CONFIRM_KEY_KEEP_KEY_SAFE_SHEET_TITLE",
                comment: "Title for a sheet warning users to their 'Backup Key' safe."
            ),
            body: OWSLocalizedString(
                "BACKUP_ONBOARDING_CONFIRM_KEY_KEEP_KEY_SAFE_SHEET_BODY",
                comment: "Body for a sheet warning users to their 'Backup Key' safe."
            ),
            primary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "BUTTON_CONTINUE",
                    comment: "Label for 'continue' button."
                ),
                action: { [weak self] _ in
                    self?.dismiss(animated: true)
                    self?.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
                    self?.navigationController?.popViewController(animated: true)
                }
            )),
            secondary: .button(HeroSheetViewController.Button(
                title: OWSLocalizedString(
                    "BACKUP_ONBOARDING_CONFIRM_KEY_SEE_KEY_AGAIN_BUTTON_TITLE",
                    comment: "Title for a button offering to let users see their 'Backup Key'."
                ),
                style: .secondary,
                action: .custom({ [weak self] _ in
                    self?.dismiss(animated: true)
                    self?.navigationController?.interactivePopGestureRecognizer?.isEnabled = true
                })
            ))
        )
        fromViewController.present(sheet, animated: true)
    }}

// MARK: -

private class BackupSettingsViewModel: ObservableObject {
    protocol ActionsDelegate: AnyObject {
        func enableBackups(implicitPlanSelection: ChooseBackupPlanViewController.PlanSelection?)

        func disableBackups()
        func showDisablingBackupsFailedSheet()

        func loadBackupSubscription() async throws -> BackupSubscriptionLoadingState.LoadedBackupSubscription
        func upgradeFromFreeToPaidPlan()
        func manageOrCancelPaidPlan()

        func performManualBackup()
        func setShouldAllowBackupUploadsOnCellular(_ newShouldAllowBackupUploadsOnCellular: Bool)

        func setOptimizeLocalStorage(_ newOptimizeLocalStorage: Bool)

        func setIsBackupDownloadQueueSuspended(_ isSuspended: Bool, backupPlan: BackupPlan)
        func setShouldAllowBackupDownloadsOnCellular()

        func showViewBackupKey()
    }

    enum BackupSubscriptionLoadingState {
        enum LoadedBackupSubscription {
            case free
            case paid(price: FiatMoney, renewalDate: Date)
            case paidButExpiring(expirationDate: Date)
            case paidButExpired(expirationDate: Date)
        }

        case loading
        case loaded(LoadedBackupSubscription)
        case networkError
        case genericError
    }

    enum BackupEnabledState {
        case enabled
        case disabled
        case disabledLocallyStillDisablingRemotely
        case disabledLocallyButDisableRemotelyFailed
    }

    @Published var backupEnabledState: BackupEnabledState
    @Published var backupSubscriptionLoadingState: BackupSubscriptionLoadingState
    @Published var backupPlan: BackupPlan

    @Published var latestBackupAttachmentDownloadUpdate: BackupSettingsAttachmentDownloadTracker.DownloadUpdate?
    @Published var latestBackupAttachmentUploadUpdate: BackupSettingsAttachmentUploadTracker.UploadUpdate?

    @Published var lastBackupDate: Date?
    @Published var lastBackupSizeBytes: UInt64?
    @Published var shouldAllowBackupUploadsOnCellular: Bool

    weak var actionsDelegate: ActionsDelegate?

    private let loadBackupSubscriptionQueue: SerialTaskQueue

    init(
        backupEnabledState: BackupEnabledState,
        backupSubscriptionLoadingState: BackupSubscriptionLoadingState,
        backupPlan: BackupPlan,
        latestBackupAttachmentDownloadUpdate: BackupSettingsAttachmentDownloadTracker.DownloadUpdate?,
        latestBackupAttachmentUploadUpdate: BackupSettingsAttachmentUploadTracker.UploadUpdate?,
        lastBackupDate: Date?,
        lastBackupSizeBytes: UInt64?,
        shouldAllowBackupUploadsOnCellular: Bool,
    ) {
        self.backupEnabledState = backupEnabledState
        self.backupSubscriptionLoadingState = backupSubscriptionLoadingState

        self.backupPlan = backupPlan
        self.latestBackupAttachmentDownloadUpdate = latestBackupAttachmentDownloadUpdate
        self.latestBackupAttachmentUploadUpdate = latestBackupAttachmentUploadUpdate

        self.lastBackupDate = lastBackupDate
        self.lastBackupSizeBytes = lastBackupSizeBytes
        self.shouldAllowBackupUploadsOnCellular = shouldAllowBackupUploadsOnCellular

        self.loadBackupSubscriptionQueue = SerialTaskQueue()
    }

    // MARK: -

    func enableBackups(implicitPlanSelection: ChooseBackupPlanViewController.PlanSelection?) {
        actionsDelegate?.enableBackups(implicitPlanSelection: implicitPlanSelection)
    }

    func disableBackups() {
        actionsDelegate?.disableBackups()
    }

    func handleDisableBackupsRemoteState(
        _ disablingRemotelyState: BackupDisablingManager.DisableRemotelyState
    ) {
        let disableRemotelyTask: Task<Void, Error>
        switch disablingRemotelyState {
        case .inProgress(let task):
            withAnimation {
                backupEnabledState = .disabledLocallyStillDisablingRemotely
            }

            disableRemotelyTask = task
        case .previouslyFailed:
            withAnimation {
                backupEnabledState = .disabledLocallyButDisableRemotelyFailed
            }

            return
        }

        Task { @MainActor in
            let newBackupEnabledState: BackupEnabledState
            do {
                try await disableRemotelyTask.value
                newBackupEnabledState = .disabled
            } catch {
                newBackupEnabledState = .disabledLocallyButDisableRemotelyFailed
                actionsDelegate?.showDisablingBackupsFailedSheet()
            }

            withAnimation {
                backupEnabledState = newBackupEnabledState
            }
        }
    }

    // MARK: -

    func loadBackupSubscription() {
        guard let actionsDelegate else { return }

        loadBackupSubscriptionQueue.enqueue { @MainActor [self, actionsDelegate] in
            withAnimation {
                backupSubscriptionLoadingState = .loading
            }

            let newLoadingState: BackupSubscriptionLoadingState
            do {
                let backupPlan = try await actionsDelegate.loadBackupSubscription()
                newLoadingState = .loaded(backupPlan)
            } catch let error where error.isNetworkFailureOrTimeout {
                newLoadingState = .networkError
            } catch {
                newLoadingState = .genericError
            }

            withAnimation {
                backupSubscriptionLoadingState = newLoadingState
            }
        }
    }

    func upgradeFromFreeToPaidPlan() {
        actionsDelegate?.upgradeFromFreeToPaidPlan()
    }

    func manageOrCancelPaidPlan() {
        actionsDelegate?.manageOrCancelPaidPlan()
    }

    // MARK: -

    func performManualBackup() {
        actionsDelegate?.performManualBackup()
    }

    func setShouldAllowBackupUploadsOnCellular(_ newShouldAllowBackupUploadsOnCellular: Bool) {
        shouldAllowBackupUploadsOnCellular = newShouldAllowBackupUploadsOnCellular
        actionsDelegate?.setShouldAllowBackupUploadsOnCellular(newShouldAllowBackupUploadsOnCellular)
    }

    // MARK: -

    var optimizeLocalStorageAvailable: Bool {
        switch backupPlan {
        case .disabled, .free:
            false
        case .paid, .paidExpiringSoon:
            true
        }
    }

    var optimizeLocalStorage: Bool {
        switch backupPlan {
        case .disabled, .free:
            false
        case .paid(let optimizeLocalStorage), .paidExpiringSoon(let optimizeLocalStorage):
            optimizeLocalStorage
        }
    }

    func setOptimizeLocalStorage(_ newOptimizeLocalStorage: Bool) {
        actionsDelegate?.setOptimizeLocalStorage(newOptimizeLocalStorage)
    }

    // MARK: -

    func setIsBackupDownloadQueueSuspended(_ isSuspended: Bool) {
        actionsDelegate?.setIsBackupDownloadQueueSuspended(isSuspended, backupPlan: backupPlan)
    }

    func setShouldAllowBackupDownloadsOnCellular() {
        actionsDelegate?.setShouldAllowBackupDownloadsOnCellular()
    }

    // MARK: -

    func showViewBackupKey() {
        actionsDelegate?.showViewBackupKey()
    }
}

// MARK: -

struct BackupSettingsView: View {
    @ObservedObject private var viewModel: BackupSettingsViewModel

    fileprivate init(viewModel: BackupSettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        SignalList {
            SignalSection {
                BackupSubscriptionView(
                    loadingState: viewModel.backupSubscriptionLoadingState,
                    viewModel: viewModel
                )
            }

            if let latestBackupAttachmentUploadUpdate = viewModel.latestBackupAttachmentUploadUpdate {
                SignalSection {
                    BackupAttachmentUploadProgressView(
                        latestUploadUpdate: latestBackupAttachmentUploadUpdate
                    )
                }
            }

            if let latestBackupAttachmentDownloadUpdate = viewModel.latestBackupAttachmentDownloadUpdate {
                SignalSection {
                    BackupAttachmentDownloadProgressView(
                        latestDownloadUpdate: latestBackupAttachmentDownloadUpdate,
                        viewModel: viewModel,
                    )
                }
            }

            switch viewModel.backupEnabledState {
            case .enabled:
                SignalSection {
                    Button {
                        viewModel.performManualBackup()
                    } label: {
                        Label {
                            Text(OWSLocalizedString(
                                "BACKUP_SETTINGS_MANUAL_BACKUP_BUTTON_TITLE",
                                comment: "Title for a button allowing users to trigger a manual backup."
                            ))
                        } icon: {
                            Image(uiImage: .backup)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                    }
                    .foregroundStyle(Color.Signal.label)
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_ENABLED_SECTION_HEADER",
                        comment: "Header for a menu section related to settings for when Backups are enabled."
                    ))
                }

                SignalSection {
                    BackupDetailsView(viewModel: viewModel)
                }

                SignalSection {
                    Toggle(
                        OWSLocalizedString(
                            "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_TOGGLE_TITLE",
                            comment: "Title for a toggle allowing users to change the Optimize Local Storage setting."
                        ),
                        isOn: Binding(
                            get: { viewModel.optimizeLocalStorage },
                            set: { viewModel.setOptimizeLocalStorage($0) }
                        )
                    ).disabled(!viewModel.optimizeLocalStorageAvailable)
                } footer: {
                    let footerText = if viewModel.optimizeLocalStorageAvailable {
                        OWSLocalizedString(
                            "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_TOGGLE_FOOTER_AVAILABLE",
                            comment: "Footer for a toggle allowing users to change the Optimize Local Storage setting, if the toggle is available."
                        )
                    } else {
                        OWSLocalizedString(
                            "BACKUP_SETTINGS_OPTIMIZE_LOCAL_STORAGE_TOGGLE_FOOTER_UNAVAILABLE",
                            comment: "Footer for a toggle allowing users to change the Optimize Local Storage setting, if the toggle is unavailable."
                        )
                    }

                    Text(footerText)
                        .foregroundStyle(Color.Signal.secondaryLabel)
                }

                SignalSection {
                    Button {
                        viewModel.disableBackups()
                    } label: {
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_DISABLE_BACKUPS_BUTTON_TITLE",
                            comment: "Title for a button allowing users to turn off Backups."
                        ))
                        .foregroundStyle(Color.Signal.red)
                    }
                } footer: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_DISABLE_BACKUPS_BUTTON_FOOTER",
                        comment: "Footer for a menu section allowing users to turn off Backups."
                    ))
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }
            case .disabled:
                SignalSection {
                    reenableBackupsButton
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_DISABLED_SECTION_FOOTER",
                        comment: "Footer for a menu section related to settings for when Backups are disabled."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }
            case .disabledLocallyStillDisablingRemotely:
                SignalSection {
                    VStack(alignment: .leading) {
                        LottieView(animation: .named("linear_indeterminate"))
                            .playing(loopMode: .loop)
                            .background {
                                Capsule().fill(Color.Signal.secondaryFill)
                            }

                        Spacer().frame(height: 16)

                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUPS_DISABLING_PROGRESS_VIEW_DESCRIPTION",
                            comment: "Description for a progress view tracking Backups being disabled."
                        ))
                        .foregroundStyle(Color.Signal.secondaryLabel)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_DISABLING_SECTION_HEADER",
                        comment: "Header for a menu section related to disabling Backups."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }
            case .disabledLocallyButDisableRemotelyFailed:
                SignalSection {
                    VStack(alignment: .center) {
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUPS_DISABLING_GENERIC_ERROR_TITLE",
                            comment: "Title for a view indicating we failed to delete the user's Backup due to an unexpected error."
                        ))
                        .bold()
                        .foregroundStyle(Color.Signal.secondaryLabel)

                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUPS_DISABLING_GENERIC_ERROR_MESSAGE",
                            comment: "Message for a view indicating we failed to delete the user's Backup due to an unexpected error."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(Color.Signal.secondaryLabel)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                } header: {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUPS_DISABLING_GENERIC_ERROR_SECTION_HEADER",
                        comment: "Header for a menu section related to settings for when disabling Backups encountered an unexpected error."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
                }

                SignalSection {
                    reenableBackupsButton
                }
            }
        }
    }

    /// A button to enable Backups if it was previously disabled, if we can let
    /// the user reenable.
    private var reenableBackupsButton: AnyView {
        let implicitPlanSelection: ChooseBackupPlanViewController.PlanSelection?
        switch viewModel.backupSubscriptionLoadingState {
        case .loading, .networkError:
            // Don't let them reenable until we know if they're already paying
            // or not.
            return AnyView(EmptyView())
        case .loaded(.free), .loaded(.paidButExpired), .genericError:
            // Let the reenable with anything.
            implicitPlanSelection = nil
        case .loaded(.paid), .loaded(.paidButExpiring):
            // Only let the user reenable with .paid, because they're already
            // paying.
            implicitPlanSelection = .paid
        }

        return AnyView(
            Button {
                viewModel.enableBackups(implicitPlanSelection: implicitPlanSelection)
            } label: {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_REENABLE_BACKUPS_BUTTON_TITLE",
                    comment: "Title for a button allowing users to re-enable Backups, after it had been previously disabled."
                ))
            }
                .buttonStyle(.plain)
        )
    }
}

// MARK: -

private struct BackupAttachmentDownloadProgressView: View {
    let latestDownloadUpdate: BackupSettingsAttachmentDownloadTracker.DownloadUpdate
    let viewModel: BackupSettingsViewModel

    var body: some View {
        VStack(alignment: .leading) {
            let progressViewColor: Color? = switch latestDownloadUpdate.state {
            case .suspended:
                nil
            case .running, .pausedLowBattery, .pausedNeedsWifi, .pausedNeedsInternet:
                .Signal.accent
            case .outOfDiskSpace:
                .yellow
            }

            let subtitleText: String = switch latestDownloadUpdate.state {
            case .suspended:
                switch viewModel.backupPlan {
                case .disabled, .free, .paid:
                    String(
                        format: OWSLocalizedString(
                            "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_SUSPENDED",
                            comment: "Subtitle for a view explaining that downloads are available but not running. Embeds {{ the amount available to download as a file size, e.g. 100 MB }}."
                        ),
                        latestDownloadUpdate.totalBytesToDownload.formatted(.byteCount(style: .decimal))
                    )
                case .paidExpiringSoon:
                    String(
                        format: OWSLocalizedString(
                            "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_SUSPENDED_PAID_SUBSCRIPTION_EXPIRING",
                            comment: "Subtitle for a view explaining that downloads are available but not running, and the user's paid subscription is expiring. Embeds {{ the amount available to download as a file size, e.g. 100 MB }}."
                        ),
                        latestDownloadUpdate.totalBytesToDownload.formatted(.byteCount(style: .decimal))
                    )
                }
            case .running:
                String(
                    format: OWSLocalizedString(
                        "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_RUNNING",
                        comment: "Subtitle for a progress bar tracking active downloading. Embeds 1:{{ the amount downloaded as a file size, e.g. 100 MB }}; 2:{{ the total amount to download as a file size, e.g. 1 GB }}; 3:{{ the amount downloaded as a percentage, e.g. 10% }}."
                    ),
                    latestDownloadUpdate.bytesDownloaded.formatted(.byteCount(style: .decimal)),
                    latestDownloadUpdate.totalBytesToDownload.formatted(.byteCount(style: .decimal)),
                    latestDownloadUpdate.percentageDownloaded.formatted(.percent.precision(.fractionLength(0))),
                )
            case .pausedLowBattery:
                OWSLocalizedString(
                    "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_PAUSED_LOW_BATTERY",
                    comment: "Subtitle for a progress bar tracking downloads that are paused because of low battery."
                )
            case .pausedNeedsWifi:
                OWSLocalizedString(
                    "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_PAUSED_NEEDS_WIFI",
                    comment: "Subtitle for a progress bar tracking downloads that are paused because they need WiFi."
                )
            case .pausedNeedsInternet:
                OWSLocalizedString(
                    "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_PAUSED_NEEDS_INTERNET",
                    comment: "Subtitle for a progress bar tracking downloads that are paused because they need internet."
                )
            case .outOfDiskSpace(let bytesRequired):
                String(
                    format: OWSLocalizedString(
                        "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_SUBTITLE_PAUSED_NEEDS_DISK_SPACE",
                        comment: "Subtitle for a progress bar tracking downloads that are paused because they need more disk space available. Embeds {{ the amount of space needed as a file size, e.g. 100 MB }}."
                    ),
                    bytesRequired.formatted(.byteCount(style: .decimal))
                )
            }

            if let progressViewColor {
                ProgressView(value: latestDownloadUpdate.percentageDownloaded)
                    .progressViewStyle(.linear)
                    .tint(progressViewColor)
                    .scaleEffect(x: 1, y: 1.5)
                    .padding(.vertical, 12)

                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(Color.Signal.secondaryLabel)
            } else {
                Text(subtitleText)
            }
        }

        switch latestDownloadUpdate.state {
        case .suspended:
            Button {
                viewModel.setIsBackupDownloadQueueSuspended(false)
            } label: {
                Label {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_ACTION_BUTTON_INITIATE_DOWNLOAD",
                        comment: "Title for a button shown in Backup Settings that lets a user initiate an available download."
                    ))
                    .foregroundStyle(Color.Signal.label)
                } icon: {
                    Image(uiImage: .arrowCircleDown)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(Color.Signal.label)
        case .running, .outOfDiskSpace:
            Button {
                viewModel.setIsBackupDownloadQueueSuspended(true)
            } label: {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_ACTION_BUTTON_CANCEL_DOWNLOAD",
                    comment: "Title for a button shown in Backup Settings that lets a user cancel an in-progress download."
                ))
            }
            .foregroundStyle(Color.Signal.label)
        case .pausedNeedsWifi:
            Button {
                viewModel.setShouldAllowBackupDownloadsOnCellular()
            } label: {
                Label {
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_DOWNLOAD_PROGRESS_ACTION_BUTTON_RESUME_DOWNLOAD_WITHOUT_WIFI",
                        comment: "Title for a button shown in Backup Settings that lets a user resume a download paused due to needing Wi-Fi."
                    ))
                } icon: {
                    Image(uiImage: .arrowCircleDown)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(Color.Signal.label)
        case .pausedLowBattery, .pausedNeedsInternet:
            EmptyView()
        }
    }
}

// MARK: -

private struct BackupAttachmentUploadProgressView: View {
    let latestUploadUpdate: BackupSettingsAttachmentUploadTracker.UploadUpdate

    var body: some View {
        VStack(alignment: .leading) {
            ProgressView(value: latestUploadUpdate.percentageUploaded)
                .progressViewStyle(.linear)
                .tint(Color.Signal.accent)
                .scaleEffect(x: 1, y: 1.5)
                .padding(.vertical, 12)

            let subtitleText: String = switch latestUploadUpdate.state {
            case .running:
                String(
                    format: OWSLocalizedString(
                        "BACKUP_SETTINGS_UPLOAD_PROGRESS_SUBTITLE_RUNNING",
                        comment: "Subtitle for a progress bar tracking active uploading. Embeds 1:{{ the amount uploaded as a file size, e.g. 100 MB }}; 2:{{ the total amount to upload as a file size, e.g. 1 GB }}; 3:{{ the amount uploaded as a percentage, e.g. 10% }}."
                    ),
                    latestUploadUpdate.bytesUploaded.formatted(.byteCount(style: .decimal)),
                    latestUploadUpdate.totalBytesToUpload.formatted(.byteCount(style: .decimal)),
                    latestUploadUpdate.percentageUploaded.formatted(.percent.precision(.fractionLength(0))),
                )
            case .pausedLowBattery:
                OWSLocalizedString(
                    "BACKUP_SETTINGS_UPLOAD_PROGRESS_SUBTITLE_PAUSED_LOW_BATTERY",
                    comment: "Subtitle for a progress bar tracking uploads that are paused because of low battery."
                )
            case .pausedNeedsWifi:
                OWSLocalizedString(
                    "BACKUP_SETTINGS_UPLOAD_PROGRESS_SUBTITLE_PAUSED_NEEDS_WIFI",
                    comment: "Subtitle for a progress bar tracking uploads that are paused because they need WiFi."
                )
            }

            Text(subtitleText)
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)
        }
    }
}

// MARK: -

private struct BackupSubscriptionView: View {
    let loadingState: BackupSettingsViewModel.BackupSubscriptionLoadingState
    let viewModel: BackupSettingsViewModel

    var body: some View {
        switch loadingState {
        case .loading:
            VStack(alignment: .center) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    // Force SwiftUI to redraw this if it re-appears (e.g.,
                    // because the user retried loading) instead of reusing one
                    // that will have stopped animating.
                    .id(UUID())
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
        case .loaded(let loadedBackupSubscription):
            loadedView(
                loadedBackupSubscription: loadedBackupSubscription,
                viewModel: viewModel
            )
        case .networkError:
            VStack(alignment: .center) {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_NETWORK_ERROR_TITLE",
                    comment: "Title for a view indicating we failed to fetch someone's Backup plan due to a network error."
                ))
                .font(.subheadline)
                .bold()
                .foregroundStyle(Color.Signal.secondaryLabel)

                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_NETWORK_ERROR_MESSAGE",
                    comment: "Message for a view indicating we failed to fetch someone's Backup plan due to a network error."
                ))
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)

                Spacer().frame(height: 16)

                Button {
                    viewModel.loadBackupSubscription()
                } label: {
                    Text(CommonStrings.retryButton)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(Color.Signal.secondaryFill)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)
        case .genericError:
            VStack(alignment: .center) {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_GENERIC_ERROR_TITLE",
                    comment: "Title for a view indicating we failed to fetch someone's Backup plan due to an unexpected error."
                ))
                .font(.subheadline)
                .bold()
                .foregroundStyle(Color.Signal.secondaryLabel)

                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_BACKUP_PLAN_GENERIC_ERROR_MESSAGE",
                    comment: "Message for a view indicating we failed to fetch someone's Backup plan due to an unexpected error."
                ))
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 140)
        }
    }

    private func loadedView(
        loadedBackupSubscription: BackupSettingsViewModel.BackupSubscriptionLoadingState.LoadedBackupSubscription,
        viewModel: BackupSettingsViewModel
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Group {
                    switch loadedBackupSubscription {
                    case .free:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_FREE_HEADER",
                            comment: "Header describing what the free backup plan includes."
                        ))
                    case .paid, .paidButExpiring, .paidButExpired:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_HEADER",
                            comment: "Header describing what the paid backup plan includes."
                        ))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.Signal.secondaryLabel)

                Spacer().frame(height: 8)

                switch loadedBackupSubscription {
                case .free:
                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUP_PLAN_FREE_DESCRIPTION",
                        comment: "Text describing the user's free backup plan."
                    ))
                case .paid(let price, let renewalDate):
                    let renewalStringFormat = OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUP_PLAN_PAID_RENEWAL_FORMAT",
                        comment: "Text explaining when the user's paid backup plan renews. Embeds {{ the formatted renewal date }}."
                    )
                    let priceStringFormat = OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUP_PLAN_PAID_PRICE_FORMAT",
                        comment: "Text explaining the price of the user's paid backup plan. Embeds {{ the formatted price }}."
                    )

                    Text(String(
                        format: priceStringFormat,
                        CurrencyFormatter.format(money: price)
                    ))
                    Text(String(
                        format: renewalStringFormat,
                        DateFormatter.localizedString(from: renewalDate, dateStyle: .medium, timeStyle: .none)
                    ))
                case .paidButExpiring(let expirationDate), .paidButExpired(let expirationDate):
                    let expirationDateFormatString = switch loadedBackupSubscription {
                    case .free, .paid:
                        owsFail("Not possible")
                    case .paidButExpiring:
                        OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_FUTURE_EXPIRATION_FORMAT",
                            comment: "Text explaining that a user's paid plan, which has been canceled, will expire on a future date. Embeds {{ the formatted expiration date }}."
                        )
                    case .paidButExpired:
                        OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_PAST_EXPIRATION_FORMAT",
                            comment: "Text explaining that a user's paid plan, which has been canceled, expired on a past date. Embeds {{ the formatted expiration date }}."
                        )
                    }

                    Text(OWSLocalizedString(
                        "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_DESCRIPTION",
                        comment: "Text describing that the user's paid backup plan has been canceled."
                    ))
                    .foregroundStyle(Color.Signal.red)
                    Text(String(
                        format: expirationDateFormatString,
                        DateFormatter.localizedString(from: expirationDate, dateStyle: .medium, timeStyle: .none)
                    ))
                }

                Spacer().frame(height: 16)

                Button {
                    switch loadedBackupSubscription {
                    case .free:
                        viewModel.upgradeFromFreeToPaidPlan()
                    case .paid, .paidButExpiring, .paidButExpired:
                        viewModel.manageOrCancelPaidPlan()
                    }
                } label: {
                    switch loadedBackupSubscription {
                    case .free:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_FREE_ACTION_BUTTON_TITLE",
                            comment: "Title for a button allowing users to upgrade from a free to paid backup plan."
                        ))
                    case .paid:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_ACTION_BUTTON_TITLE",
                            comment: "Title for a button allowing users to manage or cancel their paid backup plan."
                        ))
                    case .paidButExpiring, .paidButExpired:
                        Text(OWSLocalizedString(
                            "BACKUP_SETTINGS_BACKUP_PLAN_PAID_BUT_CANCELED_ACTION_BUTTON_TITLE",
                            comment: "Title for a button allowing users to reenable a paid backup plan that has been canceled."
                        ))
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .foregroundStyle(Color.Signal.label)
                .padding(.top, 8)
            }

            Spacer()

            Image("backups-subscribed")
                .frame(width: 56, height: 56)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}

// MARK: -

private struct BackupDetailsView: View {
    let viewModel: BackupSettingsViewModel

    var body: some View {
        HStack {
            let lastBackupMessage: String? = {
                guard let lastBackupDate = viewModel.lastBackupDate else {
                    return nil
                }

                let lastBackupDateString = DateFormatter.localizedString(from: lastBackupDate, dateStyle: .medium, timeStyle: .none)
                let lastBackupTimeString = DateFormatter.localizedString(from: lastBackupDate, dateStyle: .none, timeStyle: .short)

                if Calendar.current.isDateInToday(lastBackupDate) {
                    let todayFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_TODAY_FORMAT",
                        comment: "Text explaining that the user's last backup was today. Embeds {{ the time of the backup }}."
                    )

                    return String(format: todayFormatString, lastBackupTimeString)
                } else if Calendar.current.isDateInYesterday(lastBackupDate) {
                    let yesterdayFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_YESTERDAY_FORMAT",
                        comment: "Text explaining that the user's last backup was yesterday. Embeds {{ the time of the backup }}."
                    )

                    return String(format: yesterdayFormatString, lastBackupTimeString)
                } else {
                    let pastFormatString = OWSLocalizedString(
                        "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_PAST_FORMAT",
                        comment: "Text explaining that the user's last backup was in the past. Embeds 1:{{ the date of the backup }} and 2:{{ the time of the backup }}."
                    )

                    return String(format: pastFormatString, lastBackupDateString, lastBackupTimeString)
                }
            }()

            Text(OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_LAST_BACKUP_LABEL",
                comment: "Label for a menu item explaining when the user's last backup occurred."
            ))
            Spacer()
            if let lastBackupMessage {
                Text(lastBackupMessage)
                    .foregroundStyle(Color.Signal.secondaryLabel)
            }
        }

        HStack {
            Text(OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_BACKUP_SIZE_LABEL",
                comment: "Label for a menu item explaining the size of the user's backup."
            ))
            Spacer()
            if let lastBackupSizeBytes = viewModel.lastBackupSizeBytes {
                Text(lastBackupSizeBytes.formatted(.byteCount(style: .decimal)))
                    .foregroundStyle(Color.Signal.secondaryLabel)
            }
        }

        Toggle(
            OWSLocalizedString(
                "BACKUP_SETTINGS_ENABLED_BACKUP_ON_CELLULAR_LABEL",
                comment: "Label for a toggleable menu item describing whether to make backups on cellular data."
            ),
            isOn: Binding(
                get: { viewModel.shouldAllowBackupUploadsOnCellular },
                set: { viewModel.setShouldAllowBackupUploadsOnCellular($0) }
            )
        )

        Button {
            viewModel.showViewBackupKey()
        } label: {
            HStack {
                Text(OWSLocalizedString(
                    "BACKUP_SETTINGS_ENABLED_VIEW_BACKUP_KEY_LABEL",
                    comment: "Label for a menu item offering to show the user their backup key."
                ))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.Signal.secondaryLabel)
            }
        }
        .foregroundStyle(Color.Signal.label)

    }
}

// MARK: - Previews

#if DEBUG

private extension BackupSettingsViewModel {
    static func forPreview(
        backupEnabledState: BackupEnabledState,
        latestBackupAttachmentDownloadUpdateState: BackupSettingsAttachmentDownloadTracker.DownloadUpdate.State? = nil,
        latestBackupAttachmentUploadUpdateState: BackupSettingsAttachmentUploadTracker.UploadUpdate.State? = nil,
        backupPlanLoadResult: Result<BackupSubscriptionLoadingState.LoadedBackupSubscription, Error>,
    ) -> BackupSettingsViewModel {
        class PreviewActionsDelegate: ActionsDelegate {
            private let backupPlanLoadResult: Result<BackupSubscriptionLoadingState.LoadedBackupSubscription, Error>
            init(backupPlanLoadResult: Result<BackupSubscriptionLoadingState.LoadedBackupSubscription, Error>) {
                self.backupPlanLoadResult = backupPlanLoadResult
            }

            func enableBackups(implicitPlanSelection: ChooseBackupPlanViewController.PlanSelection?) { print("Enabling! implicitPlanSelection: \(implicitPlanSelection as Any)") }
            func disableBackups() { print("Disabling!") }
            func showDisablingBackupsFailedSheet() { print("Showing disabling-Backups-failed sheet!") }

            func loadBackupSubscription() async throws -> BackupSettingsViewModel.BackupSubscriptionLoadingState.LoadedBackupSubscription {
                try! await Task.sleep(nanoseconds: 2.clampedNanoseconds)
                return try backupPlanLoadResult.get()
            }
            func upgradeFromFreeToPaidPlan() { print("Upgrading!") }
            func manageOrCancelPaidPlan() { print("Managing or canceling!") }

            func performManualBackup() { print("Manually backing up!") }
            func setShouldAllowBackupUploadsOnCellular(_ newShouldAllowBackupUploadsOnCellular: Bool) { print("Uploads on cellular: \(newShouldAllowBackupUploadsOnCellular)") }

            func setOptimizeLocalStorage(_ newOptimizeLocalStorage: Bool) { print("Optimize local storage: \(newOptimizeLocalStorage)") }

            func setIsBackupDownloadQueueSuspended(_ isSuspended: Bool, backupPlan: BackupPlan) { print("Download queue suspended: \(isSuspended) \(backupPlan)") }
            func setShouldAllowBackupDownloadsOnCellular() { print("Downloads on cellular: true") }

            func showViewBackupKey() { print("Showing View Backup Key!") }
        }

        let viewModel = BackupSettingsViewModel(
            backupEnabledState: backupEnabledState,
            backupSubscriptionLoadingState: .loading,
            backupPlan: {
                switch backupPlanLoadResult {
                case .success(.paid):
                    return .paid(optimizeLocalStorage: false)
                case .success(.paidButExpiring), .success(.paidButExpired):
                    return .paidExpiringSoon(optimizeLocalStorage: false)
                case .success(.free), .failure:
                    return .free
                }
            }(),
            latestBackupAttachmentDownloadUpdate: latestBackupAttachmentDownloadUpdateState.map {
                BackupSettingsAttachmentDownloadTracker.DownloadUpdate(
                    state: $0,
                    bytesDownloaded: 1_400_000_000,
                    totalBytesToDownload: 1_600_000_000,
                )
            },
            latestBackupAttachmentUploadUpdate: latestBackupAttachmentUploadUpdateState.map {
                BackupSettingsAttachmentUploadTracker.UploadUpdate(
                    state: $0,
                    bytesUploaded: 400_000_000,
                    totalBytesToUpload: 1_600_000_000,
                )
            },
            lastBackupDate: Date().addingTimeInterval(-1 * .day),
            lastBackupSizeBytes: 2_400_000_000,
            shouldAllowBackupUploadsOnCellular: false
        )
        let actionsDelegate = PreviewActionsDelegate(backupPlanLoadResult: backupPlanLoadResult)
        viewModel.actionsDelegate = actionsDelegate
        ObjectRetainer.retainObject(actionsDelegate, forLifetimeOf: viewModel)

        viewModel.loadBackupSubscription()
        return viewModel
    }
}

#Preview("Plan: Paid") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .success(.paid(
            price: FiatMoney(currencyCode: "USD", value: 1.99),
            renewalDate: Date().addingTimeInterval(.week)
        ))
    ))
}

#Preview("Plan: Free") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Plan: Expiring") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .success(.paidButExpiring(
            expirationDate: Date().addingTimeInterval(.week)
        ))
    ))
}

#Preview("Plan: Expired") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .success(.paidButExpired(
            expirationDate: Date().addingTimeInterval(-1 * .week)
        ))
    ))
}

#Preview("Plan: Network Error") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .failure(OWSHTTPError.networkFailure(.genericTimeout))
    ))
}

#Preview("Plan: Generic Error") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        backupPlanLoadResult: .failure(OWSGenericError(""))
    ))
}

#Preview("Downloads: Suspended") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .suspended,
        backupPlanLoadResult: .success(.paid(
            price: FiatMoney(currencyCode: "USD", value: 1.99),
            renewalDate: Date().addingTimeInterval(.week)
        ))
    ))
}

#Preview("Downloads: Suspended w/o Paid Plan") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .suspended,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Downloads: Running") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .running,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Downloads: Paused (Battery)") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .pausedLowBattery,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Downloads: Paused (WiFi)") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .pausedNeedsWifi,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Downloads: Paused (Internet)") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .pausedNeedsInternet,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Downloads: Disk Space Error") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentDownloadUpdateState: .outOfDiskSpace(bytesRequired: 200_000_000),
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Uploads: Running") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentUploadUpdateState: .running,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Uploads: Paused (WiFi)") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentUploadUpdateState: .pausedNeedsWifi,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Uploads: Paused (Battery)") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .enabled,
        latestBackupAttachmentUploadUpdateState: .pausedLowBattery,
        backupPlanLoadResult: .success(.free)
    ))
}

#Preview("Disabling: Success") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .disabled,
        backupPlanLoadResult: .success(.free),
    ))
}

#Preview("Disabling: Remotely") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .disabledLocallyStillDisablingRemotely,
        backupPlanLoadResult: .success(.free),
    ))
}

#Preview("Disabling: Remotely Failed") {
    BackupSettingsView(viewModel: .forPreview(
        backupEnabledState: .disabledLocallyButDisableRemotelyFailed,
        backupPlanLoadResult: .success(.free),
    ))
}

#endif
