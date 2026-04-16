# U盘虾 软件说明

## 1. 软件简介
U盘虾是一个可放在本地磁盘或 U 盘直接运行的便携式 AI 助手软件。  
主要特点：
- 自带运行环境，无需单独安装 Node.js
- 支持 Windows 与 macOS 一键启动
- 自带网页配置中心，可管理模型、渠道与技能

## 2. 启动方式

### Windows
1. 双击 `Windows-一键启动.bat`
2. 程序会自动打开对话页与配置中心
3. 使用过程中不要关闭启动窗口

### macOS
1. 双击 `Mac-一键启动.command`
2. 首次运行可能会进行初始化，然后自动打开浏览器
3. 使用过程中保持脚本窗口开启

## 3. 主要目录说明
- `Windows-一键启动.bat`：Windows 启动入口
- `Mac-一键启动.command`：macOS 启动入口
- `oc/app/`：程序核心文件与运行时
- `oc/config-server/`：配置中心服务
- `oc/data/`：运行数据（配置、会话、日志、记忆、备份）
- `oc/skills-cn/`：预置技能目录

## 4. 端口说明
- 对话页（Gateway）默认扫描：`18789-18799`
- 配置中心（Config Center）默认扫描：`18788-18798`
- 如端口被占用，会自动切换到下一个可用端口

## 5. 数据与配置位置
- `oc/data/.openclaw/openclaw.json`：主配置文件
- `oc/data/.openclaw/agents/`：会话与 Agent 状态
- `oc/data/memory/`：记忆数据
- `oc/data/logs/`：日志
- `oc/data/backups/`：备份

## 6. 客服二维码
配置中心“联系客服”支持微信与 Telegram 二维码，上下显示。

二维码文件位置：
- `oc/config-server/public/support/二维码.JPG`（微信）
- `oc/config-server/public/support/TG二维码.jpg`（Telegram）

微信客服二维码：

![微信客服二维码](oc/config-server/public/support/二维码.JPG)

Telegram 客服二维码：

![Telegram 客服二维码](oc/config-server/public/support/TG二维码.jpg)

## 7. 常见问题

### 仍出现旧聊天记录或旧模型配置
当前运行目录中仍有历史数据。  
清理 `oc/data/.openclaw`、`oc/data/memory`、`oc/data/logs`、`oc/data/backups` 后重启即可。

### 一键启动后页面打不开
- 确认启动窗口仍在运行
- 检查端口是否被其他程序占用
- 重新执行一键启动脚本

## 8. 安全建议
- 不要在配置文件长期保存生产环境密钥
- 如密钥泄露，立即在服务商后台轮换
- 对外分发前，清理 `oc/data/` 下运行痕迹

## 9. 发布打包（推荐）
- 在仓库根目录执行：`bash release.sh v0.0.2`
- 产物默认输出到：`dist/u-fresh-claw-v0.0.2.zip`
- 同时生成：`dist/u-fresh-claw-v0.0.2.zip.sha256`
- 打包时会自动排除：`.git`、`oc/data/`、日志、系统垃圾文件
