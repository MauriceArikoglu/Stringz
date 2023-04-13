//
//  MainWindow.swift
//  Stringz
//
//  Created by Heysem Katibi on 12/23/16.
//  Copyright © 2016 Heysem Katibi. All rights reserved.
//

import Foundation
import Cocoa
import XcodeProj
import PathKit
import FileWatcher
import Combine

class MainWindowController: NSWindowController, NSWindowDelegate, EditorManagerDelegate {
  var appDelegate: AppDelegate {
    NSApplication.shared.delegate as! AppDelegate
  }
  
  @IBOutlet weak var toolbar: NSToolbar!
  @IBOutlet weak var addLanguagePopUpButton: NSPopUpButton!
  @IBOutlet weak var searchField: InfoSearchField!
  
  var watchFileSubscriber: AnyCancellable?
  var unwatchFileSubscriber: AnyCancellable?
  var saveFileSubscribers: [String: AnyCancellable] = [:]
  var autosaveFileSubscribers: [String: AnyCancellable] = [:]
  
  var dirtyFilesUUids: [String] = [] {
    didSet {
      setDocumentEdited(dirtyFilesUUids.count != 0)
    }
  }
  
  var tableView: NSTableView? {
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return nil
    }
    
    return main.editorViewController.tableView
  }
  
  override var undoManager: UndoManager? {
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return nil
    }
    
    return main.undoManager
  }
  
  
  // MARK: - Current Project
  var currentProjectPath: Path? {
    didSet {
      loadProject()
    }
  }
  
  var editorManager: EditorManager!
  
  private(set) var localizables: [Localizable] = []
  private(set) var selectedLocalizableIndex: Int = -1
  
  var importerOptions: ImporterOptions!
  
  
  // MARK: - Properties
  private var documentUpdated: Bool {
    return dirtyFilesUUids.count != 0
  }
  
  // MARK: - Overrides
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    editorManager = EditorManager(delegate: self)
  }
  
  override func windowDidLoad() {
    super.windowDidLoad()
    
    importerOptions = ImporterOptions(
      importAllPlistKeys: UserDefaults.plistImportAll,
      plistKeys: UserDefaults.plistKeys,
      
      ignoreEmptyValues: UserDefaults.importingIgnoreEmpty,
      ignoreOnlyWhitespaceValues: UserDefaults.importingIgnoreOnlyWhitespace,
      ignoreUnusedValuesInStoryboards: UserDefaults.importingIgnoreUnusedInStoryboards,
      ignoreCommentsInStoryboards: UserDefaults.importingIgnoreCommentsInStoryboards,
      ignoredValues: UserDefaults.importingIgnoredValues,
      
      exportOrder: ExportOrder(rawValue: UserDefaults.exportingStringsOrder) ?? .sameAsOriginal,
      commentStyle: CommentStyle(rawValue: UserDefaults.exportingCommentStyle) ?? .line,
      emptyLines: EmptyLines(rawValue: UserDefaults.exportingEmptyLines) ?? .beforeComments,
      
      xcodePath: UserDefaults.storyboardXcodePath
    )
    
    self.setupListeners()
    
    addLanguagePopUpButton.target = self
    
    Language
      .allCases
      .forEach { language in
        let menuItem = NSMenuItem()
        menuItem.title = language.fiendlyName
        menuItem.identifier = NSUserInterfaceItemIdentifier(rawValue: language.rawValue)
        menuItem.action = #selector(self.performAddLanguage(_:))
        
        self.addLanguagePopUpButton.menu?.addItem(menuItem)
      }
  }
  
  func windowWillClose(_ notification: Notification) {
    self.cancelListeners()
    self.window = nil
    self.editorManager.cancel()
    
    appDelegate.windowCountDidChange()
  }
  
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    return closeDocument()
  }
  
  
  // MARK: - Actions
  @objc func performSave(_ sender: Any) {
    guard documentUpdated else { return }
    saveAll()
  }
  
  @objc func performRevertToSaved(_ sender: Any) {
    
  }
  
  @objc func performFilter(_ sender: Any) {
    if let identifier = (sender as? NSMenuItem)?.identifier {
      switch identifier {
      case .showAll:
        UserDefaults.searchType = .all
        break
        
      case .showUntranslated:
        UserDefaults.searchType = .untranslated
        break
        
      case .showTranslated:
        UserDefaults.searchType = .translated
        break
        
      default:
        break
      }
    } else if let selection = (sender as? NSSegmentedControl)?.selectedSegment {
      switch selection {
      case 0:
        UserDefaults.searchType = .all
        break
        
      case 1:
        UserDefaults.searchType = .untranslated
        break
        
      case 2:
        UserDefaults.searchType = .translated
        break
        
      default:
        break
      }
    }
    
    toolbar.validateVisibleItems()
  }
  
  @objc func customizeToolbar(_ sender: Any) {
    
  }
  
  @objc func performAddLanguage(_ sender: Any) {
    
    guard
      let menuItem = sender as? NSMenuItem,
      let languageString = menuItem.identifier?.rawValue,
      let language = Language(rawValue: languageString)
    else {
      return
    }
    
    //    localizeFile()
    
    self.addLanguage(language, at: 0, with: nil, in: self.selectedLocalizableIndex)
  }
  
  @objc func performAddString(_ sender: Any) {
    guard let selectedLocalizable = self.selectedLocalizable else {
      return
    }
    
    let viewController = AddStringViewController.instantiateFromStoryboard()
    
    viewController.validationHandler = { key in
      return !selectedLocalizable.valueSets.contains(key: key)
    }
    
    viewController.addStringHandler = { key in
      let valueSet = ValueSet(key: key)
      self.addValueSets([valueSet])
    }
    
    self.contentViewController?.presentAsSheet(viewController)
  }
  
  @objc func performRemoveString(_ sender: Any) {
    guard let tableView = self.tableView else {
      return
    }
    
    if tableView.selectedColumnIndexes.count == 1 {
      let columndIndex = tableView.selectedColumn
      let identifier = tableView.tableColumns[columndIndex].identifier.rawValue
      
      if let language = Language(rawValue: identifier) {
        self.removeLanguage(language, in: selectedLocalizableIndex)
      }
      
    } else if tableView.selectedRowIndexes.count != 0 {
      let valueSets = tableView.selectedRowIndexes.map { self.editorManager.data[$0] }
      
      self.removeValueSets(valueSets, from: selectedLocalizableIndex)
    }
  }
  
  @objc func performLocalize(_ sender: Any) {
    self.localizeFile(selectedLocalizableIndex)
  }
  
  @objc func toggleKeyColumn(_ sender: Any) {
    UserDefaults.showKeyColumn = !UserDefaults.showKeyColumn
  }
  
  @objc func toggleCommentColumn(_ sender: Any) {
    UserDefaults.showCommentColumn = !UserDefaults.showCommentColumn
  }
  
  override func performTextFinderAction(_ sender: Any?) {
    print("performTextFinderAction")
  }
  
  @objc func performFindPanelAction(_ sender: Any?) {
    print("performFindPanelAction")
  }
  
  
  // MARK: - Helpers
  func closeDocument() -> Bool {
    if !documentUpdated {
      currentProjectPath = nil
      return true
    } else {
      var projectName = ""
      
      if let name = self.currentProjectPath?.lastComponent {
        projectName = " \"\(name)\""
      }
      
      Common.alert(
        message: "Do you want to save the changes made to the project\(projectName)?",
        informative: "You can revert to undo the changes since you last saved the project.",
        positiveButton: "Save",
        negativeButton: "Cancel",
        neutralButton: "Revert Changes",
        window: self.window) { response in
          
          switch (response) {
          case NSApplication.ModalResponse.alertFirstButtonReturn:
            self.performSave(self)
            self.close()
            self.appDelegate.continueQuitting(didClose: true)
            break
            
          case NSApplication.ModalResponse.alertThirdButtonReturn:
            self.currentProjectPath = nil
            self.dirtyFilesUUids.removeAll()
            self.close()
            self.appDelegate.continueQuitting(didClose: true)
            break
            
          default:
            self.appDelegate.continueQuitting(didClose: false)
            break
          }
        }
      
      return false
    }
  }
  
}

extension MainWindowController {
  
  func loadProject() {
    guard let currentProjectPath = self.currentProjectPath else {
      self.localizables.removeAll()
      return
    }
    
    // Load the localizables in the project
    self.localizables = IosImporter.loadProject(from: currentProjectPath, with: &importerOptions)
    
    // Notifiy sidebar and table view to reload content
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    main.sidebarViewController.outlineView.reloadData()
    
    DispatchQueue.main.async {
      main.sidebarViewController.outlineView.expandItem(nil, expandChildren: true)
    }
    
    if UserDefaults.generalAutoload {
      self.loadLocalizables(localizables.sorted(by: { $0 < $1 }))
    }
  }
  
  func loadLocalizables(_ localizables: [Localizable]) {
    
    DispatchQueue.global().async {
      for localizable in localizables where localizable.status == .unloaded {
        DispatchQueue.main.async {
          localizable.status = .loading
          
          guard
            let main = self.contentViewController as? MainViewController
          else {
            return
          }
          
          main.sidebarViewController.outlineView.animator().reloadItem(localizable)
          
          if self.localizables.firstIndex(of: localizable) == self.selectedLocalizableIndex {
            self.selectLocalizable(self.selectedLocalizableIndex, reload: true)
          }
        }
        
        var valueSets: [ValueSet] = []
        
        for file in localizable.files where file.type != .storyboard || file.type != .xib {
          
          let values = IosImporter.values(in: file, with: self.importerOptions)
          
          for value in values {
            let valueSet = valueSets.setOrAppend(value: value.value, for: value.key, and: file.language)
            
            valueSet.set(originalIndex: value.originalIndex, for: file.language)
            valueSet.set(variableName: value.variableName, for: file.language)
            
            if valueSet.comment.isEmpty {
              valueSet.comment = value.comment
            }
          }
          
          NotificationCenter
            .default
            .post(name: .startWatchingFile,
                  object: nil,
                  userInfo: ["uuid": file.uuid])
        }
        
        DispatchQueue.main.async {
          localizable.valueSets.append(contentsOf: valueSets)
          localizable.status = .ready
          
          guard
            let main = self.contentViewController as? MainViewController
          else {
            return
          }
          
          main.sidebarViewController.outlineView.reloadItem(localizable)
          
          if self.localizables.firstIndex(of: localizable) == self.selectedLocalizableIndex {
            self.selectLocalizable(self.selectedLocalizableIndex, reload: true)
          }
        }
      }
    }
  }
  
  func unloadLocalizables(_ localizables: [Localizable]) {
    for localizable in localizables where localizable.status == .ready {
      
      for file in localizable.files {
        NotificationCenter
          .default
          .post(name: .stopWatchingFile, object: nil, userInfo: ["uuid": file.uuid])
      }
      
      localizable.valueSets.removeAll()
      localizable.status = .unloaded
      
      guard
        let main = self.contentViewController as? MainViewController
      else {
        return
      }
      
      main.sidebarViewController.outlineView.reloadItem(localizable)
      
      if self.localizables.firstIndex(of: localizable) == self.selectedLocalizableIndex {
        self.selectLocalizable(self.selectedLocalizableIndex, reload: true)
      }
    }
  }
  
  func selectLocalizable(
    _ localizableIndex: Int,
    reload: Bool = false
  ) {
    
    guard
      reload || self.selectedLocalizableIndex != localizableIndex
    else {
      return
    }
    
    self.selectedLocalizableIndex = localizableIndex
    self.editorManager.selectLocalizable(at: localizableIndex)
    
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    main.sidebarViewController.selectLocalizable(at: localizableIndex)
    main.editorViewController.selectLocalizable(at: localizableIndex)
  }
  
  func addValueSets(
    _ valueSets: [ValueSet],
    to localizableIndex: Int? = nil,
    registerActionName: Bool = true
  ) {
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    
    guard
      localizableIndex >= 0, localizables.count > localizableIndex
    else {
      return
    }
    
    // Add value sets to the localizable
    let localizable = self.localizables[localizableIndex]
    localizable.valueSets.append(contentsOf: valueSets)
    
    editorManager.reloadChanges(in: localizableIndex)
    editorManager.select(valueSets: valueSets, in: localizableIndex, reloadIfNecessary: true)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.removeValueSets(valueSets, from: localizableIndex, registerActionName: false)
    }
    
    if registerActionName {
      undoManager?.setActionName("Adding")
    }
    
    // AutoSave affected files
    valueSets.availableLanguages
      .map { localizable.file(for: $0) }
      .forEach { file in
        
        guard let file = file else { return }
        
        self.dirtyFilesUUids.append(file.uuid)
        
        NotificationCenter
          .default
          .post(name: .shouldAutosaveFile(uuid: file.uuid), object: nil)
      }
  }
  
  func removeValueSets(
    _ valueSets: [ValueSet],
    from localizableIndex: Int? = nil,
    registerActionName: Bool = true
  ) {
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    
    guard
      localizableIndex >= 0,
      localizables.count > localizableIndex
    else {
      return
    }
    
    // Remove value sets from the localizable
    let localizable = self.localizables[localizableIndex]
    localizable.valueSets.removeAll { valueSets.contains($0) }
    
    editorManager.reloadChanges(in: localizableIndex)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.addValueSets(valueSets, to: localizableIndex, registerActionName: false)
    }
    
    if registerActionName {
      undoManager?.setActionName("Removing")
    }
    
    // Save affected files
    valueSets.availableLanguages
      .map { localizable.file(for: $0) }
      .forEach { file in
        
        guard let file = file else { return }
        
        self.dirtyFilesUUids.append(file.uuid)
        
        NotificationCenter
          .default
          .post(name: .shouldAutosaveFile(uuid: file.uuid), object: nil)
      }
  }
  
  func updateValueSet(
    _ valueSet: ValueSet,
    with identifier: String,
    newValue: String,
    in localizableIndex: Int? = nil,
    registerActionName: Bool = true
  ) {
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    
    guard
      localizableIndex >= 0,
      localizables.count > localizableIndex
    else {
      return
    }
    
    // Set new value in updated value set
    let localizable = self.localizables[localizableIndex]
    var oldValue = ""
    
    if identifier == "key" {
      oldValue = valueSet.key
    } else if identifier == "comment" {
      oldValue = valueSet.comment
    } else {
      oldValue = valueSet.value(for: Language(rawValue: identifier)!)?.value ?? ""
    }
    
    if newValue == oldValue { return }
    
    if identifier == "key" {
      valueSet.key = newValue
      
      // Add new key to plist keys
      if localizables.first(where: { $0.valueSets.contains(valueSet) })?.localizableType == .config {
        self.importerOptions.plistKeys.appendIfDoesntExist(newValue)
      }
    } else if identifier == "comment" {
      valueSet.comment = newValue
    } else {
      valueSet.setOrAppend(value: newValue, for: Language(rawValue: identifier)!)
    }
    
    editorManager.reloadChanges(in: localizableIndex, including: [valueSet])
    editorManager.select(valueSets: [valueSet], in: localizableIndex, reloadIfNecessary: true)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.updateValueSet(valueSet, with: identifier, newValue: oldValue, in: localizableIndex, registerActionName: false)
    }
    
    if registerActionName {
      undoManager?.setActionName("Typing")
    }
    
    // Save affected files
    var affectedFiles: [File?]
    
    if identifier == "key" || identifier == "comment" {
      affectedFiles = valueSet.availableLanguages.map { localizable.file(for: $0) }
    } else {
      affectedFiles = [localizable.file(for: Language(rawValue: identifier)!)]
    }
    
    affectedFiles.forEach { file in
      guard let file = file else { return }
      
      self.dirtyFilesUUids.append(file.uuid)
      
      NotificationCenter
        .default
        .post(name: .shouldAutosaveFile(uuid: file.uuid),
              object: nil)
    }
  }
  
  func addLanguage(
    _ language: Language,
    at fileIndex: Int,
    with data: Data?,
    in localizableIndex: Int? = nil)
  {
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    
    // Select related localizable
    self.selectLocalizable(localizableIndex)
    
    // Add new language to the localizable (if possible)
    let localizable = self.localizables[localizableIndex]
    
    guard
      !localizable.languages.contains(language),
      let currentProjectPath = self.currentProjectPath,
      let file = IosImporter.addLanguage(language, to: localizable.name, with: data ?? Data(), in: currentProjectPath)
    else {
      return
    }
    
    localizable.files.insert(file, at: fileIndex)
    
    // Notify table view to reload language columns
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    main.editorViewController.selectLocalizable(at: localizableIndex)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.removeLanguage(language, in: localizableIndex)
    }
    
    undoManager?.setActionName("Adding Language")
    
    // Start watching newly added file
    NotificationCenter
      .default
      .post(name: .startWatchingFile,
            object: nil,
            userInfo: ["uuid": file.uuid])
  }
  
  func removeLanguage(_ language: Language, in localizableIndex: Int? = nil) {
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    
    // Select related localizable
    self.selectLocalizable(localizableIndex)
    
    // Remove language file from the localizable (if possible)
    let localizable = self.localizables[localizableIndex]
    
    guard
      let currentProjectPath = self.currentProjectPath,
      let file = localizable.file(for: language),
      file.type == .strings,
      let fileIndex = localizable.files.firstIndex(where: { $0.language == language }),
      let data = IosImporter.removeLanguage(file: file, in: currentProjectPath)
    else {
      return
    }
    
    localizable.files.removeAll(where: { $0.language == language })
    
    // Notify table view to reload language columns
    
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    main.editorViewController.selectLocalizable(at: localizableIndex)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.addLanguage(language, at: fileIndex, with: data, in: localizableIndex)
    }
    undoManager?.setActionName("Removing Language")
    
    // Stop watching the removed file
    NotificationCenter.default.post(name: .stopWatchingFile, object: nil, userInfo: ["uuid": file.uuid])
  }
  
  func localizeFile(_ localizableIndex: Int? = nil, registerActionName: Bool = true) {
    guard let currentProjectPath = self.currentProjectPath else {
      return
    }

    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    var localizable = self.localizables[localizableIndex]
    
    // Localize the file
    do {
      try IosImporter.localize(&localizable, in: currentProjectPath)
    } catch {
      // ToDo: Send error report to AppCenter
      return
    }
    
    // Notify sidebar and table view to show file as localized
    let localizableType = localizable.localizableType
    
    let oldIndexInParent = main
      .sidebarViewController
      .outlineView
      .childIndex(forItem: localizable)

    let newIndexInParent = self.localizables
      .filter(for: localizableType,
              includeUnlocalized: UserDefaults.generalShowUnlocalizedFiles)
      .sorted(by: { $0 < $1 })
      .firstIndex(of: localizable)!
    
    main
      .sidebarViewController
      .outlineView
      .moveItem(at: oldIndexInParent,
                inParent: localizableType,
                to: newIndexInParent,
                inParent: localizableType)
    
    main
      .sidebarViewController
      .outlineView
      .reloadItem(localizable)
    
    self.loadLocalizables([localizable])
    self.selectLocalizable(localizableIndex, reload: true)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.unlocalizeFile(localizableIndex, registerActionName: false)
    }
    
    if registerActionName {
      undoManager?.setActionName("Localizing")
    }
  }
  
  func unlocalizeFile(_ localizableIndex: Int? = nil, registerActionName: Bool = true) {
    guard let currentProjectPath = self.currentProjectPath else {
      return
    }
    
    guard
      let main = self.contentViewController as? MainViewController
    else {
      return
    }
    
    let localizableIndex = localizableIndex ?? self.selectedLocalizableIndex
    var localizable = self.localizables[localizableIndex]
    
    // Stop watching localized file before unlocalizing it
    self.unloadLocalizables([localizable])
    
    // Unlocalize the file
    do {
      try IosImporter.unlocalize(&localizable, in: currentProjectPath)
    } catch {
      // ToDo: Send error report to AppCenter
      return
    }
    
    // Notify sidebar and table view to show file as unlocalized
    let localizableType = localizable.localizableType
    
    let oldIndexInParent = main
      .sidebarViewController
      .outlineView
      .childIndex(forItem: localizable)
    
    let newIndexInParent = self.localizables
      .filter(for: localizableType,
              includeUnlocalized: UserDefaults.generalShowUnlocalizedFiles)
      .sorted(by: { $0 < $1 })
      .firstIndex(of: localizable)!
    
    main
      .sidebarViewController
      .outlineView
      .moveItem(at: oldIndexInParent,
                inParent: localizableType,
                to: newIndexInParent,
                inParent: localizableType)
    
    main
      .sidebarViewController
      .outlineView
      .reloadItem(localizable)
    
    self.selectLocalizable(localizableIndex, reload: true)
    
    // Register undo action
    undoManager?.registerUndo(withTarget: self) { _ in
      self.localizeFile(localizableIndex, registerActionName: false)
    }
    if registerActionName {
      undoManager?.setActionName("Unlocalizing")
    }
  }
  
  func saveAll() {
    self.dirtyFilesUUids.uniqued().forEach { uuid in
      guard
        let (localizable, file) = self.localizables.first(byFileUUID: uuid)
      else {
        return
      }
      
      let values = localizable.values(byLanguage: file.language)
      IosImporter.save(file: file, values: values, with: self.importerOptions)
    }
    
    self.dirtyFilesUUids.removeAll()
  }
  
}

extension MainWindowController {
  
  private func setupListeners() {
    func sink(_ note: Notification.Name, debounceMs ms: Int, _ handler: @escaping (Notification) -> ()) -> AnyCancellable {
      NotificationCenter
        .default
        .publisher(for: note)
        .receive(on: RunLoop.main)
        .debounce(for: .milliseconds(ms), scheduler: DispatchQueue.global())
        .sink(receiveValue: handler)
    }
    
    let saveHandler = { [weak self] (sender: Notification) in
      DispatchQueue.main.async {
        guard
          let zelf = self,
          let uuid = sender.name.rawValue.components(separatedBy: ".").last,
          zelf.dirtyFilesUUids.contains(uuid),
          let (localizable, file) = zelf.localizables.first(byFileUUID: uuid)
        else {
          return
        }
        
        let values = localizable.values(byLanguage: file.language)
        
        zelf.dirtyFilesUUids.removeAll(where: { $0 == uuid })
        
        IosImporter
          .save(file: file, values: values, with: zelf.importerOptions)
        
        print("save: \(sender.name)")

      }
    }
    
    let autosaveHandler = { (sender: Notification) in
      guard UserDefaults.generalAutosave else {
        return
      }
      
      saveHandler(sender)
      
      print("autosave: \(sender.name)")
    }
    
    let startHandler = { [weak self] (sender: Notification) in
      guard
        let zelf = self,
        let uuid = sender.userInfo?["uuid"] as? String
      else {
        return
      }
      
      zelf.saveFileSubscribers[uuid] = sink(.shouldSaveFile(uuid: uuid), debounceMs: 50, saveHandler)
      
      zelf.autosaveFileSubscribers[uuid] = sink(.shouldAutosaveFile(uuid: uuid), debounceMs: 300, autosaveHandler)
      
      print("watch - watcher count: \(zelf.saveFileSubscribers.count)")
    }
    
    let stopHandler = { [weak self] (sender: Notification) in
      guard
        let zelf = self,
        let uuid = sender.userInfo?["uuid"] as? String
      else {
        return
      }
      
      zelf.saveFileSubscribers.removeValue(forKey: uuid)?.cancel()
      zelf.autosaveFileSubscribers.removeValue(forKey: uuid)?.cancel()
      
      print("unwatch - watcher count: \(zelf.saveFileSubscribers.count)")
    }
    
    self.watchFileSubscriber = sink(.startWatchingFile, debounceMs: 300, startHandler)
    self.unwatchFileSubscriber = sink(.stopWatchingFile, debounceMs: 0, stopHandler)
    
  }
  
  private func cancelListeners() {
    self.watchFileSubscriber?.cancel()
    self.watchFileSubscriber = nil
    
    self.unwatchFileSubscriber?.cancel()
    self.unwatchFileSubscriber = nil
    
    self.saveFileSubscribers.forEach { $0.value.cancel() }
    self.saveFileSubscribers.removeAll()
    
    self.autosaveFileSubscribers.forEach { $0.value.cancel() }
    self.autosaveFileSubscribers.removeAll()
    
    print("cancel - watcher count: \(self.saveFileSubscribers.count)")
  }
}

// MARK: - NSSearchFieldDelegate Protocol
extension MainWindowController: NSSearchFieldDelegate {
  
  @objc func performFind(_ sender: Any) {
    searchField.becomeFirstResponder()
  }
  
  @objc func performFindNext(_ sender: Any) {
    editorManager.selectSearchResult(which: .next)
  }
  
  @objc func performFindPrevious(_ sender: Any) {
    editorManager.selectSearchResult(which: .previous)
  }
  
  @IBAction func searchScopeChanged(_ sender: Any) {
    guard
      let identifier = (sender as? NSMenuItem)?.identifier
    else {
      return
    }
    
    switch identifier {
    case .scopeAll: UserDefaults.searchScope = .all
    case .scopeCurrent: UserDefaults.searchScope = .current
    default: break
    }
  }
  
  @IBAction func searchFieldsChanged(_ sender: Any) {
    guard
      let identifier = (sender as? NSMenuItem)?.identifier
    else {
      return
    }
    
    let field: SearchField?
    
    switch identifier {
    case .fieldsKey: field = .key
    case .fieldsComment: field = .comment
    case .fieldsValues: field = .values
    default: field = nil
    }
    
    if let field = field {
      var searchFields = UserDefaults.searchFields
      
      if let index = searchFields.firstIndex(of: field) {
        searchFields.remove(at: index)
      } else {
        searchFields.append(field)
      }
      
      UserDefaults.searchFields = searchFields
    }
  }
  
  @IBAction func searchModeChanged(_ sender: Any) {
    guard
      let identifier = (sender as? NSMenuItem)?.identifier
    else {
      return
    }
    
    switch identifier {
    case .modeContains:
      UserDefaults.searchMode = .contains
      break
      
    case .modeStartsWith:
      UserDefaults.searchMode = .startsWith
      break
      
    case .modeEndsWith:
      UserDefaults.searchMode = .endsWith
      break
      
    case .modeRegularExpression:
      UserDefaults.searchMode = .regularExpression
      break
      
    default:
      break
    }
  }
  
  @IBAction func searchOptionsChanged(_ sender: Any) {
    guard
      let identifier = (sender as? NSMenuItem)?.identifier
    else {
      return
    }
    
    switch identifier {
    case .optionsMatchCase:
      UserDefaults.searchMatchCase = !UserDefaults.searchMatchCase
      break
      
    case .optionsMatchWords:
      UserDefaults.searchMatchWords = !UserDefaults.searchMatchWords
      break
      
    default:
      break
    }
  }
  
  @IBAction func searchFieldAction(_ sender: Any) {
    
  }
  
  func controlTextDidChange(_ obj: Notification) {
    if searchField.stringValue.isEmpty {
      editorManager.searchQueryDebouncer.callImmediately(userInfo: "")
    } else {
      editorManager.searchQueryDebouncer.call(userInfo: searchField.stringValue)
    }
  }
  
  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool
  {
    if commandSelector == #selector(NSResponder.insertNewline) {
      editorManager.selectSearchResult(which: .next)
      return true
    }
    
    if commandSelector == #selector(NSResponder.cancelOperation) {
      editorManager.searchQueryDebouncer.callImmediately(userInfo: "")
      tableView?.superview?.superview?.becomeFirstResponder()
      return true
    }
    
    return false
  }
  
}

extension MainWindowController: NSToolbarDelegate {
  
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.toggleSidebar,
            .addLanguage,
            .addString,
            .removeString,
            .filter,
            .find,
            .space,
            .flexibleSpace]
  }
  
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    return [.toggleSidebar,
            .flexibleSpace,
            .addLanguage,
            .space,
            .addString,
            .removeString,
            .space,
            .filter,
            .space,
            .find]
  }
  
}

extension MainWindowController: NSMenuItemValidation, NSToolbarItemValidation {
  
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let identifier = menuItem.identifier
    else { return false }
    
    let ready = selectedLocalizable?.status == .ready || selectedLocalizable?.status == .saving
    let strings = selectedLocalizable?.localizableType == .strings || selectedLocalizable?.localizableType == .config
    
    switch identifier {
    case .addLanguage:
      return ready && selectedLocalizable?.localizableType != .config
      
    case .addString:
      return ready && strings
      
    case .removeString:
      return ready && strings && tableView?.selectedRow != -1
      
    case .showAll:
      menuItem.state = editorManager.searchType == .all ? .on : .off
      return ready
      
    case .showUntranslated:
      menuItem.state = editorManager.searchType == .untranslated ? .on : .off
      return ready
      
    case .showTranslated:
      menuItem.state = editorManager.searchType == .translated ? .on : .off
      return ready
      
    case .toggleKeyColumn:
      menuItem.title = UserDefaults.showKeyColumn ? "Hide Key Column" : "Show Key Column"
      return ready
      
    case .toggleCommentColumn:
      menuItem.title = UserDefaults.showCommentColumn ? "Hide Comment Column" : "Show Comment Column"
      return ready
      
    case let identifier where Language(rawValue: identifier.rawValue) != nil:
      let language = Language(rawValue: identifier.rawValue)!
      let hasLanguage = selectedLocalizable?.languages.contains(language) ?? false
      menuItem.state = hasLanguage ? .on : .off
      return true
      
    case .scopeAll:
      menuItem.state = editorManager.searchScope == .all ? .on : .off
      return true
      
    case .scopeCurrent:
      menuItem.state = editorManager.searchScope == .current ? .on : .off
      return true
      
    case .fieldsKey:
      menuItem.state = editorManager.searchFields.contains(.key) ? .on : .off
      return true
      
    case .fieldsComment:
      menuItem.state = editorManager.searchFields.contains(.comment) ? .on : .off
      return true
      
    case .fieldsValues:
      menuItem.state = editorManager.searchFields.contains(.values) ? .on : .off
      return true
      
    case .modeContains:
      menuItem.state = editorManager.searchMode == .contains ? .on : .off
      return true
      
    case .modeStartsWith:
      menuItem.state = editorManager.searchMode == .startsWith ? .on : .off
      return true
      
    case .modeEndsWith:
      menuItem.state = editorManager.searchMode == .endsWith ? .on : .off
      return true
      
    case .modeRegularExpression:
      menuItem.state = editorManager.searchMode == .regularExpression ? .on : .off
      return true
      
    case .optionsMatchCase:
      let regularExpression = editorManager.searchMode == .regularExpression
      menuItem.state = regularExpression || !editorManager.matchCase ? .off : .on
      return !regularExpression
      
    case .optionsMatchWords:
      let regularExpression = editorManager.searchMode == .regularExpression
      menuItem.state = regularExpression || !editorManager.matchWords ? .off : .on
      return !regularExpression
      
    case .find, .findSelection:
      return ready
      
    case .findNext, .findPrevious:
      return ready && !editorManager.searchQuery.isEmpty
      
    default:
      return false
    }
  }
  
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    let ready = selectedLocalizable?.status == .ready || selectedLocalizable?.status == .saving
    let strings = selectedLocalizable?.localizableType == .strings || selectedLocalizable?.localizableType == .config
    
    switch item.itemIdentifier {
    case .addLanguage:
      return ready && selectedLocalizable?.localizableType != .config
      
    case .addString:
      return ready && strings
      
    case .removeString:
      return ready && strings && tableView?.selectedRow != -1
      
    case .filter:
      (item.view as! NSSegmentedControl).selectedSegment = editorManager.searchType.rawValue
      return ready
      
    case .find:
      let scope = editorManager.searchScope
      let regularExpression = editorManager.searchMode == .regularExpression
      let matchCase = editorManager.matchCase
      let matchWords = editorManager.matchWords
      
      let ph = "Find in \(scope == .all ? "All Files" : "Current File")"
      
      if regularExpression {
        searchField.placeholderString = [ph, "(RegEx)"].joined(separator: " ")
      } else if matchCase && matchWords {
        searchField.placeholderString = [ph, "(Match Case and Words)"].joined(separator: " ")
      } else if matchCase {
        searchField.placeholderString = [ph, "(Match Case)"].joined(separator: " ")
      } else if matchWords {
        searchField.placeholderString = [ph, "(Match Words)"].joined(separator: " ")
      }
      
      return ready
      
    default:
      return false
    }
  }
  
}
