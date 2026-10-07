# Dock Exposé

This is the public website and release repository for Dock Exposé.

Dock Exposé is a macOS app that lets you preview apps and folders on the dock via click or hover, prevents space swooshing, and restores the bottom bar for app exposé after Golden Gate (macOS 27) stopped showing it, leaving users without a familiar way to view recent items and minimized windows for an app. It also provides extras like:

- Edit recent items directly in app exposé or force the bottom-bar to show outside it (Fn+R)
- ⌘+click to cycle windows, ⇧+click to make a new window
- adds close/minimize buttons to Mission Control / App Exposé
- click to toggle hide/show dock apps
- preview folders on the dock

### Dock Exposé app download link:

Latest release: **Dock Exposé 4.00.2**

https://github.com/steventheworker/Dock-Expose-home/releases/download/v4.00.1/Dock-Expose-4.00.1.zip

You can also browse all releases on the [Dock Exposé GitHub Releases page](https://github.com/steventheworker/Dock-Expose-home/releases).

## Installation

1. Download the ZIP from the release link above.
2. Double-click the ZIP to extract Dock Exposé.
3. Move `Dock Exposé.app` to your Applications folder.
4. Open the app from Applications.
5. Complete the permissions setup when Dock Exposé asks for it.

Dock Exposé is distributed unnotarized. If macOS prevents the first launch, Control-click or right-click the app, choose **Open**, and confirm that you want to open it. After the first launch, it can be opened normally.

## Required permissions (2)

### Accessibility

Accessibility access allows Dock Exposé to observe and manage application windows, display previews in response to Dock and Exposé actions, and perform window controls such as close and minimize.

Enable it in **System Settings → Privacy & Security → Accessibility**.

### Screen Recording

Screen Recording access is required even when the custom bottom bar is disabled. macOS protects the information Dock Exposé needs to identify windows and display their contents behind this permission.

Screen Recording allows Dock Exposé to:

- read window titles
- screenshot minimized windows (for display in the custom bottom bar)

### Optional: Full Disk Access

Needed for the Recents Editor to read and edit recent-document information that macOS stores in protected locations. If you do not use the Recents Editor's recent-file features, you can leave Full Disk Access disabled.

For more detail, see the [permissions and setup guide](https://dockexpose.netlify.app/docs/permissions).

## Compatibility

- Apple-silicon Mac
- macOS 26 or macOS 27
- Accessibility permission enabled
- Screen Recording permission enabled
- Full Disk Access optional, only for protected recent-document access

## More information

Visit [dockexpose.netlify.app](https://dockexpose.netlify.app) for documentation, screenshots, compatibility details, and the changelog.

### Also: Check out https://dockalttab.netlify.app
