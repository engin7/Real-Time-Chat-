/// Copyright (c) 2018 Razeware LLC
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in
/// all copies or substantial portions of the Software.
///
/// Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
/// distribute, sublicense, create a derivative work, and/or sell copies of the
/// Software in any work that is designed, intended, or marketed for pedagogical or
/// instructional purposes related to programming, coding, application development,
/// or information technology.  Permission for such use, copying, modification,
/// merger, publication, distribution, sublicensing, creation of derivative works,
/// or sale is expressly withheld.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
/// THE SOFTWARE.

import UIKit
import Firebase
import MessageKit
import FirebaseFirestore
import Photos

private var messages: [Message] = []
private var messageListener: ListenerRegistration?
private let db = Firestore.firestore()
private var reference: CollectionReference?

final class ChatViewController: MessagesViewController {
  
  private let user: User
  private let channel: Channel
  
  init(user: User, channel: Channel) {
    self.user = user
    self.channel = channel
    super.init(nibName: nil, bundle: nil)
    
    title = channel.name
  }
  
  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
   
  deinit {
    messageListener?.remove()
  }

  private var isSendingPhoto = false {
    didSet {
      DispatchQueue.main.async {
        self.messageInputBar.leftStackViewItems.forEach { item in
          item.isEnabled = !self.isSendingPhoto
        }
      }
    }
  }

  private let storage = Storage.storage().reference()

  override func viewDidLoad() {
    // The id property on the channel is optional because you might not yet have synced the channel.
    guard let id = channel.id else {
       navigationController?.popViewController(animated: true)
       return
     }

     reference = db.collection(["channels", id, "thread"].joined(separator: "/"))

    super.viewDidLoad()
    
    navigationItem.largeTitleDisplayMode = .never
    
    maintainPositionOnKeyboardFrameChanged = true
    messageInputBar.inputTextView.tintColor = .primary
    messageInputBar.sendButton.setTitleColor(.primary, for: .normal)
    messageInputBar.delegate = self
    messagesCollectionView.messagesDataSource = self
    messagesCollectionView.messagesLayoutDelegate = self
    messagesCollectionView.messagesDisplayDelegate = self
    
    messageListener = reference?.addSnapshotListener { querySnapshot, error in
      guard let snapshot = querySnapshot else {
        print("Error listening for channel updates: \(error?.localizedDescription ?? "No error")")
        return
      }
      // Firestore calls this snapshot listener whenever there is a change to the database.
      snapshot.documentChanges.forEach { change in
        self.handleDocumentChange(change)
      }
    }

    // 1
    let cameraItem = InputBarButtonItem(type: .system)
    cameraItem.tintColor = .primary
    cameraItem.image = #imageLiteral(resourceName: "camera")

    // 2-Connect the new button to cameraButtonPressed().

    cameraItem.addTarget(
      self,
      action: #selector(cameraButtonPressed),
      for: .primaryActionTriggered
    )
    cameraItem.setSize(CGSize(width: 60, height: 30), animated: false)

    messageInputBar.leftStackView.alignment = .center
    messageInputBar.setLeftStackViewWidthConstant(to: 50, animated: false)

    // 3-Add the item to left side of the messege bar.
    
    messageInputBar.setStackViewItems([cameraItem], forStack: .left, animated: false)
 
  }
  
  
  // MARK: - Actions

  @objc private func cameraButtonPressed() {
    let picker = UIImagePickerController()
    picker.delegate = self

    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      picker.sourceType = .camera
    } else {
      picker.sourceType = .photoLibrary
    }

    present(picker, animated: true, completion: nil)
  }

  
  // MARK: - Helpers
  
  // This method uses the reference that was just setup. The addDocument method on the reference takes a dictionary with the keys and values that represent that data. The message data struct implements DatabaseRepresentation, which defines a dictionary property to fill out.
  
  private func save(_ message: Message) {
    reference?.addDocument(data: message.representation) { error in
      if let e = error {
        print("Error sending message: \(e.localizedDescription)")
        return
      }
      
      self.messagesCollectionView.scrollToBottom()
    }
  }

  private func uploadImage(_ image: UIImage, to channel: Channel, completion: @escaping (URL?) -> Void) {
      guard let channelID = channel.id else {
        completion(nil)
        return
      }
      
      guard let scaledImage = image.scaledToSafeUploadSize,
        let data = scaledImage.jpegData(compressionQuality: 0.4) else {
        completion(nil)
        return
      }
      
      let metadata = StorageMetadata()
      metadata.contentType = "image/jpeg"
      
      let imageName = [UUID().uuidString, String(Date().timeIntervalSince1970)].joined()
      storage.child(channelID).child(imageName).putData(data, metadata: metadata) { meta, error in
        completion(meta?.downloadURL())
      }
    }
  
  // This method takes care of updating the isSendingPhoto property to update the UI. Once the photo upload completes and the URL to that photo is returned, save a new message with that photo URL to the database.
  
  private func sendPhoto(_ image: UIImage) {
    isSendingPhoto = true
    
    uploadImage(image, to: channel) { [weak self] url in
      guard let `self` = self else {
        return
      }
      self.isSendingPhoto = false
      
      guard let url = url else {
        return
      }
      
      var message = Message(user: self.user, image: image)
      message.downloadURL = url
      
      self.save(message)
      self.messagesCollectionView.scrollToBottom()
    }
  }

  // This method makes sure the messages array doesn’t already contain the message, then adds it to the collection view. Then, if the new message is the latest and the collection view is at the bottom, scroll to reveal the new message

  private func insertNewMessage(_ message: Message) {
    guard !messages.contains(message) else {
      return
    }
    
    messages.append(message)
    messages.sort()
    
    let isLatestMessage = messages.index(of: message) == (messages.count - 1)
    let shouldScrollToBottom = messagesCollectionView.isAtBottom && isLatestMessage
    
    messagesCollectionView.reloadData()
    
    if shouldScrollToBottom {
      DispatchQueue.main.async {
        self.messagesCollectionView.scrollToBottom(animated: true)
      }
    }
  }
 
  private func handleDocumentChange(_ change: DocumentChange) {
    guard var message = Message(document: change.document) else {
      return
    }

    switch change.type {
    case .added:
      if let url = message.downloadURL {
        downloadImage(at: url) { [weak self] image in
          guard let self = self else {
            return
          }
          guard let image = image else {
            return
          }
          
          message.image = image
          self.insertNewMessage(message)
        }
      } else {
        insertNewMessage(message)
      }

    default:
      break
    }
  }

  
}
// to show image in the app
private func downloadImage(at url: URL, completion: @escaping (UIImage?) -> Void) {
  let ref = Storage.storage().reference(forURL: url.absoluteString)
  let megaByte = Int64(1 * 1024 * 1024)
  
  ref.getData(maxSize: megaByte) { data, error in
    guard let imageData = data else {
      completion(nil)
      return
    }
    
    completion(UIImage(data: imageData))
  }
}


// MARK: - MessagesDisplayDelegate

extension ChatViewController: MessagesDisplayDelegate {
  
  func backgroundColor(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> UIColor {
    
    // 1 if it’s from the current sender. If it is, you return the app’s primary green color; if not, you return a muted gray color.
    return isFromCurrentSender(message: message) ? .primary : .incomingMessage
  }

  func shouldDisplayHeader(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> Bool {

    // 2 You return false to remove the header from each message. You can use this to display thread specific information, such as a timestamp.
    return false
  }

  func messageStyle(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> MessageStyle {

    let corner: MessageStyle.TailCorner = isFromCurrentSender(message: message) ? .bottomRight : .bottomLeft

    // 3 based on who sent the message, you choose a corner for the tail of the message bubble.
    return .bubbleTail(corner, .curved)
  }
}


// MARK: - MessagesLayoutDelegate

extension ChatViewController: MessagesLayoutDelegate {

  func avatarSize(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> CGSize {

    // 1 hide avatar
    return .zero
  }

  func footerViewSize(for message: MessageType, at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> CGSize {

    // 2 Adding a little padding on the bottom of each message
    return CGSize(width: 0, height: 8)
  }

  func heightForLocation(message: MessageType, at indexPath: IndexPath,
    with maxWidth: CGFloat, in messagesCollectionView: MessagesCollectionView) -> CGFloat {

    // 3
    return 0
  }
}

// MARK: - MessagesDataSource

extension ChatViewController: MessagesDataSource {

  // 1
  func currentSender() -> Sender {
    return Sender(id: user.uid, displayName: AppSettings.displayName)
  }

  // 2
  func numberOfMessages(in messagesCollectionView: MessagesCollectionView) -> Int {
    return messages.count
  }

  // 3
  func messageForItem(at indexPath: IndexPath,
    in messagesCollectionView: MessagesCollectionView) -> MessageType {

    return messages[indexPath.section]
  }

  // 4
  func cellTopLabelAttributedText(for message: MessageType,
    at indexPath: IndexPath) -> NSAttributedString? {

    let name = message.sender.displayName
    return NSAttributedString(
      string: name,
      attributes: [
        .font: UIFont.preferredFont(forTextStyle: .caption1),
        .foregroundColor: UIColor(white: 0.3, alpha: 1)
      ]
    )
  }
}

// MARK: - MessageInputBarDelegate

extension ChatViewController: MessageInputBarDelegate {
  
  func messageInputBar(_ inputBar: MessageInputBar, didPressSendButtonWith text: String) {

    // 1-Create a message from the contents of the message bar and the current user.
    let message = Message(user: user, content: text)

    // 2-Save the message to Cloud Firestore
    save(message)

    // 3-Clear the message bar’s input field after you send the message.
    inputBar.inputTextView.text = ""
  }

}

// MARK: - UIImagePickerControllerDelegate

extension ChatViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  
  func imagePickerController(_ picker: UIImagePickerController,
                             didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    picker.dismiss(animated: true, completion: nil)
    
    // 1-If the user selected an asset, the selected image needs to be downloaded from iCloud. Request it at a fixed size. Once it’s successfully retrieved, send it.
    if let asset = info[.phAsset] as? PHAsset {
      let size = CGSize(width: 500, height: 500)
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: size,
        contentMode: .aspectFit,
        options: nil) { result, info in
          
        guard let image = result else {
          return
        }
        
        self.sendPhoto(image)
      }

    // 2-If there is an original image in the info dictionary, send that. You don’t need to worry about the original image being too large here because the storage helper handles resizing the image for you. Have a look at UIImage+Additions.swift to see how the resizing is done.
    } else if let image = info[.originalImage] as? UIImage {
      sendPhoto(image)
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true, completion: nil)
  }

  
}
