# 文件桌 · FileDesktop

[简体中文](#简体中文) · [English](#english)

## 简体中文

文件桌是用 SwiftUI 和 AppKit 编写的 macOS 文件管理器。文件浏览、搜索和加解密都在本机完成，无需账号。

### 功能

- **浏览与搜索**。在列表或网格中浏览文件，通过路径补全直达目录，按文件名或文件夹标签递归搜索。隐藏项目有独立标记，搜索结果显示所在目录。
- **文件操作**。支持范围多选、复制粘贴、移动、重命名、标签、快速预览和移到废纸篓。1.0.6 支持在文件桌与访达之间用快捷键复制粘贴、在网格中用 Shift 连选，以及移动重名项目时逐项确认替换。
- **加密与解压**。给单个文件创建受密码保护的 `.filedesk` 副本，解锁后可预览、编辑并重新加密。压缩包可用 7-Zip 就地解压。
- **工作区与外观**。侧栏提供常用位置、收藏和最近使用。左右侧栏和底部历史路径面板均可收起。设置支持简体中文、英文、浅色或深色外观，以及自定义强调色。

### 部署

运行需要 **macOS 14 或更高版本**。从源码构建需要 Git 和 **Swift 5.9 或更高版本**。如果还没有安装开发工具，请先运行 `xcode-select --install`。构建 1.0.6：

```bash
git clone --branch 1.0.6 --depth 1 https://github.com/ChenShayZeak/FileDesk.git
cd FileDesk
bash scripts/build-app.sh
open dist
```

在打开的访达窗口中，将 `FileDesktop.app` 拖入「应用程序」。从那里双击启动，或用聚焦搜索 `FileDesktop`。首次访问桌面、文稿、下载或外接磁盘时，macOS 可能会请求权限。

**更新已安装的客户端**。选择「帮助 → 检查更新…」。文件桌按版本号查找 GitHub 上最新的正式标签，经你确认后下载对应源码、编译、校验并替换本机应用。完成后退出并重新打开。更新需要网络、Git、Swift 开发工具和应用所在目录的写入权限。

**开发与发布**。在仓库根目录运行 `swift test`。打包脚本会把当前提交上的正式标签（如 `1.0.6` 或 `v1.0.6`）写入应用版本。更新器会跳过预发布标签。[源码](Sources/FileDesk) · [测试](Tests/FileDeskTests) · [打包脚本](scripts/build-app.sh)

### 用法

| 操作 | 方法 |
| --- | --- |
| 前往目录 | 按 `⌘⇧G` 输入路径，用 ↑ / ↓ 选择候选，Tab 补全，回车进入。例如输入 `~/Dow` 并按 Tab 可补全为 `~/Downloads/`。支持相对路径、空格和 `..`。用 `⌘⇧O` 打开文件夹选择器，`⌘[` / `⌘]` 后退或前进。 |
| 搜索与排序 | 按 `⌘F` 搜索当前目录及可访问的子目录。搜索沿用隐藏文件设置，跳过软件包内部和符号链接指向的目录。在「⋯」选择按名称、修改时间、大小或种类排序。按 `⌘⇧.` 切换隐藏项目，默认显示。 |
| 选择与复制 | 先点第一项，按住 Shift 点最后一项，选中整个范围。按住 ⌘ 点击可逐项添加或取消。按 `⌘C` 复制，打开目标目录按 `⌘V` 粘贴，也可粘贴到访达。用 `⌥⌘C` 复制绝对路径，每项一行。 |
| 移动与删除 | 右键选择「移到…」。目标已有同名项目时，核对来源和目标路径后选择「替换」或「跳过」，默认跳过。**替换文件夹会覆盖目标文件夹及其内容。** 用 `⌘⌫` 将所选项目移到废纸篓，`⌘⇧N` 新建文件夹。 |
| 收藏与历史 | 点目录标题旁的星标切换收藏。右上角可展开历史面板，重访通过「前往文件夹」访问过的路径，或点 × 删除记录。「最近使用」记录已打开的文件，随改名和删除同步。切回文件桌或按 `⌘R` 可同步访达中的变化。 |
| 预览、标签与终端 | 双击普通文件会用默认应用打开。右侧可查看属性或快速预览。右键文件夹可编辑访达标签。点右上角的终端按钮，在当前目录打开终端。 |
| 从访达打开 | 右键点击文件夹，选择「用文件桌打开」，也可在「服务」子菜单中找到它。在终端运行 `open -b local.filedesk.app .` 可打开当前目录。 |
| 默认打开方式 | 「文件桌 → 设为默认文件夹浏览器…」会向 macOS 请求文件夹关联。系统可能保护普通文件夹类型并拒绝请求，此时仍可通过访达右键菜单打开。工具栏的「⋯ → 默认打开方式」可关联 `.filedesk` 文件或请求恢复访达。 |
| 语言与外观 | 按 `⌘,` 打开设置。语言可选跟随系统、简体中文或 English，重启应用后生效。外观可选跟随系统、白天或夜间模式。点击自定义颜色色块可打开系统色盘，主题色立即生效。使用 Xcode 26 或更新工具链构建时，macOS 26 及以上支持液态玻璃效果。 |

**解压压缩包**。选中压缩包，按 `⌘⇧E` 或点右下角的解压图标。如果缺少 `7zz`，选择「安装并解压」即可下载并校验官方 7-Zip，安装到当前用户的应用支持目录。结果保存在压缩包旁的新文件夹，重名时自动追加数字。支持 ZIP、7z、RAR、TAR、GZip、BZip2、XZ、Zstandard 及常见组合格式（如 `.tar.gz`）。加密压缩包需使用可输入密码的解压工具。

**加密文件**。文件桌使用 AES-256-GCM 分块加密，通过 PBKDF2-HMAC-SHA256 从密码派生密钥。

1. 右键文件，选择「加密文件…」并设置密码。例如，`笔记.txt` 会生成 `笔记.txt.filedesk`。默认保留原件，也可在提示中将明文原件移到废纸篓。
2. 双击加密副本并输入密码。文件桌会创建临时解密副本，可在应用内编辑不超过 2 MiB 的 UTF-8 文本，或使用快速预览和默认应用。
3. 在外部应用编辑时，先在那里保存并关闭，再回到文件桌点「保存并关闭」。文件桌会将修改重新加密并清理临时副本。写回失败会保留副本供重试，强制退出也可能留下明文。
4. 右键选择「修改密码…」可用旧密码设置新密码。改名后仍使用原密码。即使在访达中去掉了 `.filedesk`，仍可在文件桌中双击解锁。保留原始扩展名（如 `.pdf`）有助于预览解密后的文件。

## English

FileDesktop is a macOS file manager built with SwiftUI and AppKit. Browsing, search, encryption, and decryption run locally. No account is required.

### Features

- **Browsing and search.** Browse in list or grid view, jump to folders with path completion, and search subfolders by filename or folder tag. Hidden items have a badge. Search results show their enclosing folder.
- **File operations.** Select ranges, copy and paste, move, rename, tag, preview, and move items to the Trash. Version 1.0.6 adds clipboard shortcuts that work with Finder, Shift-click range selection in the grid, and per-item replacement prompts when moving items with matching names.
- **Encryption and extraction.** Create a password-protected `.filedesk` copy of a file, unlock it to preview or edit, then save changes back to the encrypted copy. Extract archives in place with 7-Zip.
- **Workspace and appearance.** The sidebar gives you common locations, favorites, and recently opened files. Both sidebars and the path history panel can be collapsed. Settings include English and Simplified Chinese, light and dark appearances, and a custom accent color.

### Deployment

FileDesktop runs on **macOS 14 or later**. Building from source requires Git and **Swift 5.9 or later**. If the developer tools are missing, run `xcode-select --install` first. To build version 1.0.6, run:

```bash
git clone --branch 1.0.6 --depth 1 https://github.com/ChenShayZeak/FileDesk.git
cd FileDesk
bash scripts/build-app.sh
open dist
```

Drag `FileDesktop.app` from the Finder window into Applications. Double-click it there or search for `FileDesktop` in Spotlight. macOS may ask for permission the first time you access Desktop, Documents, Downloads, or an external drive.

**Update an installed copy.** Choose **Help → Check for Updates…**. FileDesktop finds the latest stable GitHub tag by version number. Once you confirm, it fetches that source, builds and verifies the app, and replaces the installed copy. Quit and reopen to finish. Updates require a network connection, Git, Swift developer tools, and write access to the installation directory.

**Development and releases.** Run `swift test` at the repository root. The build script sets the app version from a stable tag on the current commit, such as `1.0.6` or `v1.0.6`. The updater skips prerelease tags. [Source](Sources/FileDesk) · [Tests](Tests/FileDeskTests) · [Build script](scripts/build-app.sh)

### Usage

| Task | How |
| --- | --- |
| Go to a folder | Press `⌘⇧G` and type a path. Use ↑ / ↓ to choose a suggestion, Tab to complete it, and Return to open it. For example, type `~/Dow` and press Tab to complete `~/Downloads/`. Relative paths, spaces, and `..` are supported. Use `⌘⇧O` for the folder chooser and `⌘[` / `⌘]` to go back or forward. |
| Search and sort | Press `⌘F` to search the current folder and its accessible subfolders. Search respects hidden-item visibility and skips package contents and symlinked folders. Use **⋯** to sort by name, modification time, size, or kind. Press `⌘⇧.` to toggle hidden items, which are shown by default. |
| Select and copy | Click the first item, then Shift-click the last to select the range. Command-click toggles individual items. Press `⌘C`, open the destination, then press `⌘V`. You can also paste into Finder. Use `⌥⌘C` to copy absolute paths, one per line. |
| Move and delete | Right-click and choose **Move To…**. If a name already exists, check the source and destination paths, then choose **Replace** or **Skip**. Skip is the default. **Replacing a folder overwrites the destination folder and its contents.** Press `⌘⌫` to move selected items to the Trash or `⌘⇧N` to create a folder. |
| Favorites and history | Click the star beside a folder title to toggle it as a favorite. Open the history panel from the top right to revisit paths entered with Go to Folder, or click × to remove an entry. Recently opened files track renames and deletions. Switch back to FileDesktop or press `⌘R` to pick up changes from Finder. |
| Preview, tags, and Terminal | Double-click a file to open it in the default app. Use the right panel for properties or Quick Look. Right-click a folder to edit Finder tags. The terminal button at the top right opens Terminal in the current folder. |
| Open from Finder | Right-click a folder and choose **Open in FileDesktop**. It may appear in the **Services** submenu. From Terminal, run `open -b local.filedesk.app .` to open the working directory. |
| Default apps | **FileDesktop → Set as Default Folder Browser…** asks macOS to change the folder association. macOS can protect the folder type and decline the request. The Finder service remains available. Use **⋯ → Default Apps** to associate `.filedesk` files or request that folders open in Finder again. |
| Language and appearance | Press `⌘,` for Settings. Choose the system language, Simplified Chinese, or English, then reopen the app. Appearance can follow the system or use Light or Dark. Click the custom color swatch to open the system color picker. Accent changes apply immediately. Builds made with Xcode 26 or later use Liquid Glass on macOS 26 or later. |

**Extract an archive.** Select it and press `⌘⇧E`, or click the extract button at the bottom right. If `7zz` is missing, choose **Install and Extract** to download and verify the official 7-Zip build and install it in your user Application Support directory. Files go into a new folder beside the archive, with a numeric suffix if the name is taken. Supported formats include ZIP, 7z, RAR, TAR, GZip, BZip2, XZ, Zstandard, and common combinations such as `.tar.gz`. Password-protected archives require an extractor that accepts passwords.

**Encrypt a file.** FileDesktop encrypts file contents in chunks with AES-256-GCM and derives the key from your password with PBKDF2-HMAC-SHA256.

1. Right-click a file, choose **Encrypt File…**, and enter a password. For example, `notes.txt` produces `notes.txt.filedesk`. The original is kept by default. You can choose to move the plaintext original to the Trash.
2. Double-click the encrypted copy and enter its password. FileDesktop creates a temporary decrypted copy. Edit UTF-8 text up to 2 MiB in the app, use Quick Look, or open it in its default app.
3. If you edit in another app, save and close the document there first, then choose **Save and Close** in FileDesktop. FileDesktop encrypts your changes and removes the temporary copy. If saving fails, it keeps the copy for a retry. A forced quit may also leave a plaintext copy behind.
4. Right-click and choose **Change Password…** to set a new password using the old one. Renamed files still use their original password. Even if Finder removed the `.filedesk` extension, you can unlock the file inside FileDesktop. Keeping the original extension (such as `.pdf`) helps Quick Look identify the decrypted file.
