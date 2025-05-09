//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVAccessibilityCustomAction: UIAccessibilityCustomAction {
    public var messageAction: MessageAction?
}

extension ConversationViewController: UIGestureRecognizerDelegate {
    func createGestureRecognizers() {
        collectionViewTapGestureRecognizer.setTapDelegate(self)
        collectionViewTapGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewTapGestureRecognizer)

        collectionViewLongPressGestureRecognizer.addTarget(self, action: #selector(handleLongPressGesture))
        collectionViewLongPressGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewLongPressGestureRecognizer)

        collectionViewContextMenuGestureRecognizer.addTarget(self, action: #selector(handleLongPressGesture))
        collectionViewContextMenuGestureRecognizer.minimumPressDuration = 0.2
        collectionViewContextMenuGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewContextMenuGestureRecognizer)

        let collectionViewContextMenuSecondaryClickRecognizer = UITapGestureRecognizer()
        collectionViewContextMenuSecondaryClickRecognizer.addTarget(self, action: #selector(handleSecondaryClickGesture))
        collectionViewContextMenuSecondaryClickRecognizer.buttonMaskRequired = [.secondary]
        collectionViewContextMenuSecondaryClickRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewContextMenuSecondaryClickRecognizer)
        self.collectionViewContextMenuSecondaryClickRecognizer = collectionViewContextMenuSecondaryClickRecognizer

        collectionViewPanGestureRecognizer.addTarget(self, action: #selector(handlePanGesture))
        collectionViewPanGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewPanGestureRecognizer)

        collectionViewTapGestureRecognizer.require(toFail: collectionViewPanGestureRecognizer)
        collectionViewTapGestureRecognizer.require(toFail: collectionViewLongPressGestureRecognizer)

        // Allow panning with trackpad
        collectionViewPanGestureRecognizer.allowedScrollTypesMask = .continuous

        // There are cases where we don't have a navigation controller, such as if we got here through 3d touch.
        // Make sure we only register the gesture interaction if it actually exists. This helps the swipe back
        // gesture work reliably without conflict with audio scrubbing or swipe-to-repy.
        if let interactivePopGestureRecognizer = navigationController?.interactivePopGestureRecognizer {
            collectionViewPanGestureRecognizer.require(toFail: interactivePopGestureRecognizer)
        }
    }

    // TODO: Revisit
    private func cellAtPoint(_ point: CGPoint) -> CVCell? {
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return cell as? CVCell
    }

    private func cellForInteractionId(_ interactionId: String) -> CVCell? {
        // TODO: Won't this build a new cell in some cases?
        guard let indexPath = indexPath(forInteractionUniqueId: interactionId),
              let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return cell as? CVCell
    }

    // MARK: - UIGestureRecognizerDelegate

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isShowingSelectionUI else {
            return gestureRecognizer == collectionViewTapGestureRecognizer
        }

        if gestureRecognizer == collectionViewPanGestureRecognizer {
            // Only allow the pan gesture to recognize horizontal panning,
            // to avoid conflicts with the conversation view scroll view.
            let translation = collectionViewPanGestureRecognizer.translation(in: view)
            return abs(translation.x) > abs(translation.y)
        } else {
            return true
        }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Support standard long press recognizing for body text cases, and context menu long press recognizing for everything else
        let currentIsLongPressOrTap = (gestureRecognizer == collectionViewLongPressGestureRecognizer || gestureRecognizer == collectionViewContextMenuGestureRecognizer || gestureRecognizer == collectionViewTapGestureRecognizer)
        let otherIsLongPressOrTap = (otherGestureRecognizer == collectionViewLongPressGestureRecognizer || otherGestureRecognizer == collectionViewContextMenuGestureRecognizer || otherGestureRecognizer == collectionViewTapGestureRecognizer)
        return currentIsLongPressOrTap && otherIsLongPressOrTap
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        if collectionViewContextMenuSecondaryClickRecognizer == gestureRecognizer {
            return event.buttonMask == .secondary
        }

        return true
    }

    // MARK: -

    private func findCell(forGesture sender: UIGestureRecognizer) -> CVCell? {
        // Collection view is a scroll view; we want to ignore
        // cells that are scrolled offscreen.  So we first check
        // that the collection view contains the gesture location.
        guard collectionView.containsGestureLocation(sender) else {
            return nil
        }

        for cell in collectionView.visibleCells {
            guard let cell = cell as? CVCell else {
                owsFailDebug("Invalid cell")
                continue
            }
            guard cell.containsGestureLocation(sender) else {
                continue
            }
            return cell
        }
        return nil
    }
}

extension ConversationViewController: SingleOrDoubleTapGestureDelegate {

    // MARK: - Tap

    public func handleSingleTap(_ sender: SingleOrDoubleTapGestureRecognizer) -> Bool {
        // Stop any recording voice memos.
        finishRecordingVoiceMessage(sendImmediately: false)

        guard let cell = findCell(forGesture: sender) else {
            return false
        }

        if let interaction = collectionViewActiveContextMenuInteraction, interaction.contextMenuVisible {
            return false
        }

        return cell.handleTap(sender: sender, componentDelegate: self)
    }

    public func handleDoubleTap(_ sender: SingleOrDoubleTapGestureRecognizer) -> Bool {
        guard let cell = findCell(forGesture: sender) else {
            return false
        }
        guard cell.canHandleDoubleTap(sender: sender, componentDelegate: self) else {
            return false
        }

        return cell.handleDoubleTap(sender: sender, componentDelegate: self)
    }

    public func didEndGesture(_ sender: SingleOrDoubleTapGestureRecognizer, wasHandled: Bool) {
        if !wasHandled {
            dismissKeyBoard()
        }
    }
}

extension ConversationViewController {

    // MARK: - Long Press

    @objc
    func handleLongPressGesture(_ sender: UILongPressGestureRecognizer) {

        let resetLongPress = {
            self.longPressHandler = nil
            sender.isEnabled = false
            sender.isEnabled = true
        }

        switch sender.state {
        case .began:
            guard let longPressHandler = findLongPressHandler(sender: sender) else {
                resetLongPress()
                return
            }
            self.longPressHandler = longPressHandler
        case .changed:
            self.longPressHandler?.handleLongPress(sender)
        case .ended, .failed, .cancelled, .possible:
            self.longPressHandler?.handleLongPress(sender)
            resetLongPress()
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }

    @objc
    func handleSecondaryClickGesture(_ sender: UITapGestureRecognizer) {
        guard let cell = findCell(forGesture: sender) else {
            return
        }
        guard let longPressHandler = cell.findLongPressHandler(sender: sender,
                                                               componentDelegate: self) else {
            return
        }

        longPressHandler.startContextMenuGesture(cell: cell)
    }

    private func findLongPressHandler(sender: UILongPressGestureRecognizer) -> CVLongPressHandler? {
        guard let cell = findCell(forGesture: sender) else {
            return nil
        }
        guard let longPressHandler = cell.findLongPressHandler(sender: sender,
                                                               componentDelegate: self) else {
            return nil
        }
        if sender == collectionViewContextMenuGestureRecognizer {
            longPressHandler.startContextMenuGesture(cell: cell)
        } else {
            longPressHandler.startGesture(cell: cell)
        }
        return longPressHandler
    }

    // MARK: - Pan

    @objc
    func handlePanGesture(_ sender: UIPanGestureRecognizer) {
        let resetPan = {
            self.panHandler = nil
            sender.isEnabled = false
            sender.isEnabled = true
        }

        let updatePanGesture = {
            guard let panHandler = self.panHandler else {
                return
            }
            // The pan needs to operate on the current cell for this interaction.
            guard let cell = self.cellForInteractionId(panHandler.interactionId) else {
                owsFailDebug("No cell for pan.")
                resetPan()
                return
            }
            let messageSwipeActionState = self.viewState.messageSwipeActionState
            panHandler.handlePan(sender: sender,
                                 cell: cell,
                                 messageSwipeActionState: messageSwipeActionState)
        }

        switch sender.state {
        case .began:
            guard let panHandler = findPanHandler(sender: sender) else {
                resetPan()
                return
            }
            self.panHandler = panHandler
            startPanHandler(sender: sender)
        case .changed:
            updatePanGesture()
        case .ended, .failed, .cancelled, .possible:
            updatePanGesture()
            resetPan()
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }

    private func findPanHandler(sender: UIPanGestureRecognizer) -> CVPanHandler? {
        guard let cell = findCell(forGesture: sender) else {
            return nil
        }
        let messageSwipeActionState = viewState.messageSwipeActionState
        guard let panHandler = cell.findPanHandler(sender: sender,
                                                   componentDelegate: self,
                                                   messageSwipeActionState: messageSwipeActionState) else {
            return nil
        }
        return panHandler
    }

    private func startPanHandler(sender: UIPanGestureRecognizer) {
        guard let panHandler = panHandler else { return }
        guard let cell = findCell(forGesture: sender) else { return }
        panHandler.startGesture(sender: sender, cell: cell, messageSwipeActionState: viewState.messageSwipeActionState)
    }
}

// MARK: -

public struct CVLongPressHandler {
    private weak var delegate: CVComponentDelegate?
    let renderItem: CVRenderItem
    let itemViewModel: CVItemViewModelImpl

    enum GestureLocation {
        case `default`
        case media
        case sticker
        case quotedReply
        case systemMessage
        case paymentMessage
        case bodyText(item: CVTextLabel.Item)
    }
    let gestureLocation: GestureLocation

    init(delegate: CVComponentDelegate,
         renderItem: CVRenderItem,
         gestureLocation: GestureLocation) {
        self.delegate = delegate
        self.renderItem = renderItem
        self.gestureLocation = gestureLocation

        // TODO: shouldAutoUpdate?
        self.itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
    }

    func startContextMenuGesture(cell: CVCell) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        let shouldAllowReply = delegate.shouldAllowReplyForItem(itemViewModel)

        switch gestureLocation {
        case .`default`:
            delegate.didLongPressTextViewItem(cell,
                                              itemViewModel: itemViewModel,
                                              shouldAllowReply: shouldAllowReply)
        case .media:
            delegate.didLongPressMediaViewItem(cell,
                                               itemViewModel: itemViewModel,
                                               shouldAllowReply: shouldAllowReply)
        case .sticker:
            delegate.didLongPressSticker(cell,
                                         itemViewModel: itemViewModel,
                                         shouldAllowReply: shouldAllowReply)
        case .quotedReply:
            delegate.didLongPressQuote(cell,
                                       itemViewModel: itemViewModel,
                                       shouldAllowReply: shouldAllowReply)
        case .systemMessage:
            delegate.didLongPressSystemMessage(cell, itemViewModel: itemViewModel)
        case .paymentMessage:
            delegate.didLongPressPaymentMessage(cell, itemViewModel: itemViewModel, shouldAllowReply: shouldAllowReply)
        case .bodyText:
            break
        }
    }

    func startGesture(cell: CVCell) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        switch gestureLocation {
        case .bodyText(let item):
            delegate.didLongPressBodyTextItem(item)
        default:
            // Case will be handled by context menu gesture recognizer
            break
        }
    }

    func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        switch sender.state {
        case .began:
            // We use startGesture(cell:) to start handling the gesture.
            owsFailDebug("Unexpected state.")
        case .changed:
            delegate.didChangeLongPress(itemViewModel)
        case .ended:
            delegate.didEndLongPress(itemViewModel)
        case .failed, .cancelled:
            delegate.didCancelLongPress(itemViewModel)
        case .possible:
            owsFailDebug("Unexpected state.")
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }
}

// MARK: -

public class CVPanHandler {
    public enum PanType {
        case messageSwipeAction
        case scrubAudio
    }
    public let panType: PanType

    private weak var delegate: CVComponentDelegate?
    private let renderItem: CVRenderItem

    public var interactionId: String { renderItem.interactionUniqueId }

    // If the gesture ended now, would we perform a reply?
    public enum ActiveDirection {
        case left
        case right
        case none
    }
    public var activeDirection: ActiveDirection = .none
    var messageDetailViewController: MessageDetailViewController?

    public var percentDrivenTransition: UIPercentDrivenInteractiveTransition?

    init(delegate: CVComponentDelegate, panType: PanType, renderItem: CVRenderItem) {
        self.delegate = delegate
        self.panType = panType
        self.renderItem = renderItem
    }

    func startGesture(sender: UIPanGestureRecognizer,
                      cell: CVCell,
                      messageSwipeActionState: CVMessageSwipeActionState) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        // When the gesture starts, the "reference" of the initial
        // view positions should already be set, but the progress
        // should not yet be set.
        owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) == nil)

        cell.startPanGesture(sender: sender,
                             panHandler: self,
                             componentDelegate: delegate,
                             messageSwipeActionState: messageSwipeActionState)

        if panType == .messageSwipeAction {
            owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) != nil)
        }
    }

    func handlePan(sender: UIPanGestureRecognizer,
                   cell: CVCell,
                   messageSwipeActionState: CVMessageSwipeActionState) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        if panType == .messageSwipeAction {
            owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) != nil)
        }
        cell.handlePanGesture(sender: sender,
                              panHandler: self,
                              componentDelegate: delegate,
                              messageSwipeActionState: messageSwipeActionState)
    }
}
