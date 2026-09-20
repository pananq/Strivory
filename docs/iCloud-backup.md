# Strivory iCloud 备份与恢复

## 产品边界

Strivory 的 iCloud 功能备份应用自身保存的数据：已读取的 Workout 快照、CSV 导入批次、导入策略和导出显示名称。它不会向 Apple 健康写入任何数据。

删除应用会移除本机缓存；使用同一 Apple ID 重新安装后，用户可从 CloudKit 私有数据库恢复备份，再重新授权 Apple 健康以刷新当前 Workout。

## 一次性 Apple 配置

项目使用容器 `iCloud.com.pananq.strivory` 和 CloudKit 私有数据库。首次连接真机或提交包含此功能的构建前，请在 Xcode 的 Signing & Capabilities 中确认：

1. 已为目标启用 **iCloud** capability。
2. 勾选 **CloudKit**，并选择 `iCloud.com.pananq.strivory`。
3. 在 Apple Developer 的 Identifiers 页面确认该容器已关联 `com.pananq.strivory.app`。
4. 在 CloudKit Dashboard 的 Development 环境运行一次应用并开启备份，以创建 `StrivoryBackup` record type；验证后将 schema 部署至 Production。
5. 重新生成包含 iCloud capability 的 App Store provisioning profile，再归档上传。

## 验收场景

1. 导入 CSV、同步 Apple 健康后，在“设置”开启“iCloud 备份与恢复”。
2. 确认状态变为“已同步”。
3. 删除应用并重新安装，使用同一 Apple ID 打开。
4. 出现“发现 iCloud 备份”提示，选择“恢复备份”。
5. 年历立即显示备份快照；重新授权 Apple 健康后，当前 Workout 被重新读取并去重。

## Workout 删除与并发同步

- iCloud 请求返回时，会与此刻的本地数据再次合并，保留网络等待期间读取的 Workout、CSV 变更和显示名称，并补做备份。
- HealthKit 返回的已删除 Workout UUID 会保存在本机和备份中。删除标记优先于记录本身，旧备份不能重新带回这些 UUID。CSV 批次继续使用独立的批次删除标记。
- Workout、本机 HealthKit 查询进度和删除标记写在同一个原子保存的文件中；写入失败时不会推进查询进度，下次可以重新处理同一批变更。
- 更新后的首次健康同步会重新读取完整历史，补回旧版本可能漏掉的记录，并移除当前 Health 快照中已不存在的旧记录。完成后自动刷新仍使用增量查询；首页状态栏右侧的“同步”会主动重新核对完整历史。
- 旧版文件和 UserDefaults 存档会迁移，旧 iCloud JSON 仍可读取。新增信息位于原有 `payload` 内，不需要在 CloudKit Dashboard 新增字段或重新部署 schema。
- 完整查询为空时保留本地和恢复的历史，不根据“没有读到”推断删除。HealthKit 不透露读取权限是否被拒绝；只有明确返回的删除 UUID 才形成删除标记。Apple 可能清理较早的删除通知，因此不能保证自动识别修复前已丢失删除通知的全部旧记录。参见 [HKDeletedObject](https://developer.apple.com/documentation/healthkit/hkdeletedobject) 和 [HealthKit 权限说明](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)。

### 本地回归测试

在项目根目录运行：

```sh
bash Tests/run-sync-regressions.sh
```

脚本使用项目中的实际 AppStore、合并和持久化实现，通过可控的替代服务测试并发时序；不会访问真实健康数据或写入 iCloud。覆盖旧备份兼容、删除标记重启保留、网络返回期间的新增/删除/CSV/名称变更、自动补备份、完整核对、空读取保护、保存失败重试和旧存档迁移。

### 真机验证本次问题

1. 使用同一 Bundle ID 覆盖安装修复版本，保留现有本地记录，并保持原来的 iCloud 环境。
2. 确认允许读取体能训练，点击首页状态栏右侧的“同步”；检查 9 月 19 日的游泳（不少于 10 分钟）是否恢复显示。
3. 确认 9 月 14 日只保留尚未删除的足球记录；同一天仍有有效运动时，年历格子继续显示是正常的。
4. 执行 iCloud“立即同步”，等待完成后重启 App，确认游泳不消失、已删除记录不回来。
5. 再次读取健康数据和导出海报，确认首页、当天详情、年度统计和海报一致。

## 隐私维护

开启备份会将用户选择的运动数据传输到 Apple 的私有 iCloud 空间。因此每次发布包含该功能的版本前，都必须重新核对 App Store Connect 的 App Privacy 声明和公开隐私政策。
