# JiZi · 集字

一个自己走的 iOS 集字 App：**导入碑帖 → 切字 → 填释文自动打 label → 输入文字集字 → 导出作品**。

不联网、不依赖任何在线字库，字库全在你手机里。跟以观书法那个会员功能无关 —— 这是从零写的一个东西，用的是公有领域碑帖扫描件。

---

## 一、Windows 上怎么把这堆源码变成能装机的 IPA

你没有 Mac，所以走 **GitHub Actions 云端 macOS 编译 → 本地签名安装**。整条链路不需要买开发者账号。

### 1. 传到 GitHub

```powershell
cd C:\Users\XIAOCAI\Documents\jizi-ios
git init
git add .
git commit -m "JiZi 1.0.0"
git branch -M main
git remote add origin https://github.com/<你的用户名>/jizi-ios.git
git push -u origin main
```

推上去就自动开始编译（`.github/workflows/build-ipa.yml`）。

### 2. 拿 IPA

在仓库页 → **Actions** → 点进那次运行 → 页面底部 **Artifacts** → 下载 `JiZi-unsigned-ipa`，解压得到 `JiZi.ipa`。

### 3. 装到 iPhone（改签名）

无签名 IPA 不能直接装，要用自己 Apple ID 重签。Windows 上用 **Sideloadly**：

1. 装 [Sideloadly](https://sideloadly.io/) 和 **iTunes**（只装官网版，微软商店版不行，Sideloadly 需要 iTunes 的驱动）
2. 数据线连 iPhone，信任这台电脑
3. Sideloadly 里：IPA 选 `JiZi.ipa`，Apple ID 填自己的（**不需要**开发者账号，普通 Apple ID 就够）
4. Start → 输入 Apple ID 密码（有些账号要 App 专用密码，去 appleid.apple.com 生成）
5. 手机：**设置 → 通用 → VPN与设备管理 → 描述文件** → 信任你的 Apple ID
6. 打开「集字」

**免费 Apple ID 的限制**：签名 **7 天**过期，同时最多 3 个自签 App。过期后重跑一遍 Sideloadly 就行。

想让它自动续签、不用每周手动折腾：装 **AltStore** 或 **SideStore**（后者不需要常驻电脑），把 IPA 丢进去，它每周自动重签。

### 4. 想用 iOS 27 SDK 编译

分两件事说清楚：

- **App 能不能在 iOS 27 上跑** —— 能。工程 deployment target 是 17.0，用的是 SwiftUI / SwiftData / PhotosUI 这些稳定 API，向前兼容。
- **用 iOS 27 的 SDK 编译** —— 需要在 Actions 页面 **Run workflow** 里把 `runner` 换成装了新 Xcode 的镜像（正式版发布后一般是 `macos-26` 或更新的标签），`xcode` 填版本号如 `27.0`。跑之前先看第一次运行里 "看看这台 runner 有哪些 Xcode" 那步的输出，照着填。

iOS 27 SDK 还在 beta、托管镜像上还没有的时候：要么等正式版，要么用 [xcodes](https://github.com/XcodesOrg/xcodes) 在 CI 里下 beta——那需要往仓库 secrets 里塞 Apple ID 账号密码，比较折腾，一般不值当。

改完 `runner` / `xcode` 后重新跑一次即可，产物一样。

---

## 二、工程结构

```
jizi-ios/
├── project.yml                      # XcodeGen 工程定义（不用手写 .xcodeproj）
├── JiZi-Info.plist                  # 由 XcodeGen 生成
├── .github/workflows/build-ipa.yml  # 云端出 IPA
├── scripts/build-ipa.sh             # Mac 上本地出 IPA
└── Sources/
    ├── JiZiApp.swift                # @main，挂 SwiftData 容器
    ├── RootView.swift               # 三个 Tab：集字 / 字库 / 关于
    ├── Models/Models.swift          # SourceBook（碑帖）、CharacterEntry（单字）
    ├── Storage/ImageStore.swift     # 单字 PNG 落盘 + 缩略图缓存
    ├── Engine/
    │   ├── Segmenter.swift          # 投影法切字 / 网格切字 / 修边 / 方形归一
    │   └── Composer.swift           # 排版 + 渲染 + 落款印章 + 导出
    ├── Compose/ComposeView.swift    # 集字主界面
    ├── Library/LibraryView.swift    # 字库浏览、搜索、改字、删帖
    ├── Library/CandidatePicker.swift# 某个字的候选选择
    └── Import/ImportFlowView.swift  # 导入 → 切分预览 → 释文对齐 → 入库
```

数据流：

```
相册图片
  → Segmenter.segment / grid            (切出归一化坐标框)
  → 释文按阅读顺序对齐，得到每个框的 label
  → Segmenter.crop → trimInk → squarePad (裁切 → 修边 → 512×512 居中)
  → ImageStore.save                      (Documents/Library/<uuid>.png)
  → CharacterEntry 入 SwiftData
集字时：逐字查 CharacterEntry → 有多个候选就让用户挑 → Composer 渲染 → 相册 / PNG
```

---

## 三、实际操作流程

### 建字库

1. 「字库」页 → 右上 **+**
2. 从相册选碑帖扫描图（可一次选 20 张，一张 = 一页）
3. **自动切分**模式下看框对不对：
   - 框太多（噪点、虫蛀、印章被当成字）→ 把 **去噪强度** 调大
   - 框太少（笔画淡的没切出来）→ **墨色阈值** 往大调
   - 拓本（黑底白字）会自动反相，预览上会标出来
   - 行书连笔切不干净 → 换成 **网格切分**，数好「几列 × 每列几个字」，最稳
4. **阅读顺序**选对（竖排右起是绝大多数碑帖），然后在 **释文** 里把那页的字按顺序打进去。右下角会显示 `释文数 / 框数`，两边相等就对齐了
5. 填帖名 / 书家 / 字体 → **入库**。多张图会一页页接着来，帖信息共用

> 释文不用另找：碑帖原文网上一搜就有，直接粘进去。

### 集字

1. 「集字」页输入文字
2. 下面「逐字换字」条上点任意一个字 → 从字库里选别的写法（同一个字可能有十几个候选，会显示数量角标）
3. 调排版：竖排右起 / 横排左起、每行字数、字号、字距
4. 落款 + 印章：落款画在左侧竖排，印章是朱文方块，按右起两行排
5. 右上角 → **保存到相册** 或 **导出 PNG**

导出时会按**笔迹外框**（不是图片外框）归一等比缩放，所以从不同碑帖抠出来的字，视觉大小和重心是一致的 —— 这一步不做，集字出来会大小乱跳。

---

## 四、字库从哪来（都按公有领域挑）

- **Wikimedia Commons**：`Category:Rubbings of inscriptions on Chinese monumental stones`、`Category:Calligraphy of the Southern and Northern Dynasties`，大量 PD 拓本
- **Hugging Face**：`YAN-LIU05/HCSU`、`Rvosuke/BCSS`（书法单字/风格相关，先看各自 license）
- **故宫数字文物库** `digicol.dpm.org.cn`：有开放版权页，能下什么按它自己的声明来
- 唐及以前碑帖（《兰亭序》神龙本、《九成宫》《多宝塔》《曹全碑》…）原件早已过版权期，博物馆扫描件多数可自由使用，逐个看标注

单页分辨率建议 2000px 以上，切出来的字才干净。

---

## 五、已知限制（v1 诚实清单）

- **自动切分是启发式的**：投影法对楷书/隶书/篆书（字间有空白）效果好；行书草书连笔会切错，请用网格模式。
- **没有拖框微调**：v1 只给了阈值、去噪、网格三种手段。要逐框拖动增删的话得加一层编辑层，还没做。
- **字库很小的时候集字会缺字**：缺的字用浅灰系统字体占位，一眼能看出来，去补字库即可。
- **没有云端同步**：字库就在 App 沙盒里。
- **没写单元测试**：Segmenter 和 Composer 是纯函数，很好测，但我这次没加。
- **我没法在这台 Windows 上编译验证**：Swift 代码是照着 API 手写的，CI 第一次跑大概率会有几个编译错误（拼写、参数标签、并发标注之类）。**把 Actions 日志里 `错误：` / `error:` 那几行贴回来，我直接改。**

---

## 六、下一步可以加的

- [ ] 切分结果的可拖拽微调（加框 / 删框 / 拖边）
- [ ] 从「文件」App 直接读图（Info.plist 已经开了 `UIFileSharingEnabled`，只差一个目录扫描）
- [ ] 字库导出 / 导入（打包成 zip，方便换手机）
- [ ] 一次集字出多版本对比
- [ ] 侧边加题跋位置、多枚印章
- [ ] 异体字 / 繁简映射表

---

MIT。随便改。
