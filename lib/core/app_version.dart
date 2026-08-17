/// 应用版本号，登录页与 Emby 认证头共用。
///
/// 与 pubspec.yaml 的 version 保持一致；单独放一个常量是为了让登录页能显示
/// 版本（排查"装的到底是不是新包"时非常关键——versionCode 不变的覆盖安装
/// 可能被系统静默拒绝）。
const appVersion = '0.1.1';
