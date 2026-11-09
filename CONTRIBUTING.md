# 贡献说明

欢迎反馈兼容性问题、改进文档或提交代码。开始较大的功能改动前，可先开一个 Issue 说明使用场景。

1. Fork 仓库并从 `main` 创建分支。
2. 在 Apple Silicon Mac 上运行 `./build.sh`，打开生成的 `build/屏.app`。
3. 在 Pull Request 中描述改动前后的行为、测试步骤和硬件环境。涉及背光或显示模式的改动，请注明实际测试过的屏幕与连接方式。
4. 提交日志前，请删去显示器 UUID、序列号和个人路径。

`Sources/` 包含 Swift 应用与 Objective-C 硬件辅助程序，`Resources/` 包含面板和应用元数据，`Tools/` 包含图标构建脚本。
