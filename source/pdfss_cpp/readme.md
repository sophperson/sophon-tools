# dfss cpp 重构

## 编译方式

1. host模式默认主机X86_64
2. 交叉编译要求主机必须X86_64
3. linux_release.sh参数两个，第一个是架构名，第二个是lib(标记库一起编译)
4. 最终生成的程序在output下，同目录的json文件是服务配置文件，需要和程序安装在同一目录下

## 支持架构

* amd64 linux
* amd64 win
* i686 win
* arm64 linux
* loongarch64 linux
* riscv64 linux
* armbi linux
* sw_64 linux

## 示例

``` bash
./linux_release.sh host lib;
./linux_release.sh aarch64 lib;
./linux_release.sh loongarch64 lib;
./linux_release.sh sw_64 lib;
./linux_release.sh mingw64 lib;
./linux_release.sh mingw lib;
./linux_release.sh armbi lib;
./linux_release.sh riscv64 lib;
```

## 默认编译器版本

* amd64 linux gcc5.4(ubuntu16)
* amd64 win gcc13.1(arch linux)
* i686 win gcc13.1(arch linux)
* arm64 linux gcc6.3(ubuntu18)
* loongarch64 linux gcc8.3(ubuntu18)
* riscv64 linux gcc7.5(ubuntu18)
* armbi linux gcc7.5(ubuntu18)
* sw_64 linux gcc10.3(ubuntu18)

## 发布方式

使用当前目录的CPP源码编译出各个架构的运行程序，然后使用dfss_pip目录下的python工程将工具发布到pip上
