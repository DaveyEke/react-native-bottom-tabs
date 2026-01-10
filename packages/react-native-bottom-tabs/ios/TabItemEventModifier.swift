import SwiftUI
import SwiftUIIntrospect
#if !os(macOS)
import UIKit
#endif

#if !os(macOS) && !os(visionOS)

private final class TabBarDelegate: NSObject, UITabBarControllerDelegate {
  var onClick: ((_ index: Int) -> Bool)?
  var items: [TabInfo] = []

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
#if os(iOS)
    // Handle "More" Tab
    if tabBarController.moreNavigationController == viewController {
      return true
    }
#endif

    let isReselectingSameTab = tabBarController.selectedViewController == viewController

    if isReselectingSameTab {
      if let index = tabBarController.viewControllers?.firstIndex(of: viewController) {
        _ = onClick?(index)
      }

      return false
    }

    // Unfortunately, due to iOS 26 new tab switching animations, controlling state from JavaScript is causing significant delays when switching tabs.
    // See: https://github.com/callstackincubator/react-native-bottom-tabs/issues/383
    // Due to this, whether the tab prevents default has to be defined statically.
    if let index = tabBarController.viewControllers?.firstIndex(of: viewController) {
      let defaultPrevented = onClick?(index) ?? false

      if let effect = items[safe: index]?.tabIconEffect {
        animateTabIcon(tabBar: tabBarController.tabBar, at: index, effect: effect)
      }

      return !defaultPrevented
    }

    return false
  }

  private func animateTabIcon(tabBar: UITabBar, at index: Int, effect: String?) {
    var tabButtons: [UIView] = []
    findTabButtons(in: tabBar, results: &tabButtons)

    let sortedButtons = tabButtons.sorted { $0.frame.minX < $1.frame.minX }

    // Cluster buttons that are close together (within 20pt = same tab)
    var clusters: [[UIView]] = []
    for button in sortedButtons {
      if let lastCluster = clusters.last,
         let lastButton = lastCluster.last,
         abs(button.frame.minX - lastButton.frame.minX) < 20 {
        clusters[clusters.count - 1].append(button)
      } else {
        clusters.append([button])
      }
    }

    let uniqueButtons = clusters.compactMap { $0.first }

    guard let button = uniqueButtons[safe: index],
          let imageView = findImageView(in: button) else {
      return
    }

    if #available(iOS 17.0, *) {
      applySymbolEffect(to: imageView, effect: effect)
    }
  }

  private func findTabButtons(in view: UIView, results: inout [UIView]) {
    let typeName = String(describing: type(of: view))
    if typeName.contains("UITabButton") {
      results.append(view)
      return
    }
    for subview in view.subviews {
      findTabButtons(in: subview, results: &results)
    }
  }

  private func findImageView(in view: UIView) -> UIImageView? {
    for subview in view.subviews {
      if let imageView = subview as? UIImageView {
        return imageView
      }
      if let found = findImageView(in: subview) {
        return found
      }
    }
    return nil
  }

  @available(iOS 17.0, *)
  private func applySymbolEffect(to imageView: UIImageView, effect: String?) {
    switch effect {
    case "bounce":
      imageView.addSymbolEffect(.bounce)
    case "scale":
      imageView.addSymbolEffect(.scale)
    case "wiggle":
      if #available(iOS 18.0, *) {
        imageView.addSymbolEffect(.wiggle)
      } else {
        imageView.addSymbolEffect(.bounce)
      }
    default:
      imageView.addSymbolEffect(.bounce)
    }
  }
}

struct TabItemEventModifier: ViewModifier {
  let onTabEvent: (_ key: Int, _ isLongPress: Bool) -> Bool
  let items: [TabInfo]
  private let delegate = TabBarDelegate()

  func body(content: Content) -> some View {
    content
      .introspectTabView { tabController in
        handle(tabController: tabController)
      }
  }

  func handle(tabController: UITabBarController) {
    delegate.onClick = { index in
      onTabEvent(index, false)
    }
    delegate.items = items
    tabController.delegate = delegate

    // Don't register gesutre recognizer more than one time
    if objc_getAssociatedObject(tabController.tabBar, &AssociatedKeys.gestureHandler) != nil {
      return
    }

    // Remove existing long press gestures
    if let existingGestures = tabController.tabBar.gestureRecognizers {
      for gesture in existingGestures where gesture is UILongPressGestureRecognizer {
        tabController.tabBar.removeGestureRecognizer(gesture)
      }
    }

    // Create gesture handler
    let handler = LongPressGestureHandler(tabBar: tabController.tabBar) { key, isLongPress in _ = onTabEvent(key, isLongPress) }
    let gesture = UILongPressGestureRecognizer(target: handler, action: #selector(LongPressGestureHandler.handleLongPress(_:)))
    gesture.minimumPressDuration = 0.5

    objc_setAssociatedObject(tabController.tabBar, &AssociatedKeys.gestureHandler, handler, .OBJC_ASSOCIATION_RETAIN)

    tabController.tabBar.addGestureRecognizer(gesture)
  }
}

private struct AssociatedKeys {
  static var gestureHandler: UInt8 = 0
}

private class LongPressGestureHandler: NSObject {
  private weak var tabBar: UITabBar?
  private let handler: (Int, Bool) -> Void

  init(tabBar: UITabBar, handler: @escaping (Int, Bool) -> Void) {
    self.tabBar = tabBar
    self.handler = handler
    super.init()
  }

  @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began,
          let tabBar else { return }

    let location = recognizer.location(in: tabBar)

    // Get buttons and sort them by frames
    let tabBarButtons = tabBar.subviews.filter { String(describing: type(of: $0)).contains("UITabBarButton") }.sorted { $0.frame.minX < $1.frame.minX }

    for (index, button) in tabBarButtons.enumerated() {
      if button.frame.contains(location) {
        handler(index, true)
        break
      }
    }
  }

  deinit {
    if let tabBar {
      objc_setAssociatedObject(tabBar, &AssociatedKeys.gestureHandler, nil, .OBJC_ASSOCIATION_RETAIN)
    }
  }
}

extension View {
  /**
   Event for tab items. Returns true if should prevent default (switching tabs).
   */
  func onTabItemEvent(items: [TabInfo] = [], _ handler: @escaping (Int, Bool) -> Bool) -> some View {
    modifier(TabItemEventModifier(onTabEvent: handler, items: items))
  }
}

#endif
