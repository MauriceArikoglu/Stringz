//
//  AppNotifications.swift
//  Stringz
//
//  Created by Heysem Katibi on 4.12.2020.
//

import Foundation

extension Notification.Name {
  static let startWatchingFile = Self("stringz.notification.shouldWatchFile")
  static let stopWatchingFile = Self("stringz.notification.shouldUnwatchFile")

  static func shouldSaveFile(uuid: String) -> Notification.Name {
    return Self("stringz.notification.shouldSaveFile.\(uuid)")
  }
  
  static func shouldAutosaveFile(uuid: String) -> Notification.Name {
    return Self("stringz.notification.shouldAutoSaveFile.\(uuid)")
  }
  
  static func shouldReloadFile(uuid: String) -> Notification.Name {
    return Self("stringz.notification.shouldReloadFile.\(uuid)")
  }

  static let OpenProjectCount = Self("stringz.notification.OpenProjectCount")

  static let SearchQuery = Self("stringz.notification.SearchQuery")
}
