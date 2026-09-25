// 复制到项目 src/version.ts, 通常不需要改动.
//
// 发行构建在打包期通过 --define 注入版本号, 例如:
//   bun build src/cli.ts --compile --define "BUILD_VERSION=\"v1.2.3\""
//   esbuild src/cli.ts --bundle --define:BUILD_VERSION="\"v1.2.3\""
//
// 日常开发构建 (未打包) 与未注入时回落到 dev-build.
// typeof 对未声明的标识符是安全的, 不会抛 ReferenceError.
declare const BUILD_VERSION: string | undefined;

/** 当前构建应当显示的版本号. */
export const version: string = typeof BUILD_VERSION === "string" ? BUILD_VERSION : "dev-build";
