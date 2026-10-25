# 第三方声明

## Go 核心依赖

`Scripts/build.sh` 在编译核心后运行 `Scripts/collect-third-party-notices.py`，将声明生成到应用包的 `Contents/Resources/ThirdPartyNotices.txt`。生成文件属于构建产物，不手工维护依赖清单。

收集器以核心二进制的 `go version -m` 为准，保留实际模块版本、校验和及 `replace` 来源；通过相同工具链和目标参数的 `go list` 定位源码。它收集模块根目录及实际依赖包祖先目录中的 LICENSE、LICENCE、COPYING、COPYRIGHT、NOTICE、PATENTS、AUTHORS 等文本，并包含 Go 工具链和标准库相关声明。

每段文本标注模块和相对来源文件名，原文保留版权声明；不写入本机源码或模块缓存的绝对路径。缺少必须的许可证、版本与二进制不一致或声明文件无法读取时，构建明确失败。依赖源码从已经完成构建的本机模块缓存读取，收集时关闭代理下载，并以只读模块方式检查。

## 图标来源

应用图标使用 [Tabler Icons 的 network 图标](https://github.com/tabler/tabler-icons/blob/main/icons/outline/network.svg)，下载日期为 2026-10-25。原始图标和 MIT 许可证分别保存在 `network.svg`、`Tabler-LICENSE`。

`AppIcon.svg` 将白色网络线条放在蓝色渐变圆角背景上。`Scripts/build-icon.sh` 使用 macOS 自带工具生成各尺寸 ICNS，不引入应用运行时依赖。
