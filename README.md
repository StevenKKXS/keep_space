Dummy Dataset Scripts

本目录包含两个脚本，用于在集群环境中快速创建和释放“占空间用”的 dummy dataset，方便做磁盘空间测试、配额测试或模拟数据集占用。

文件说明
1. dummy_dataset_create.sh

用于创建一个 dummy dataset 目录，并在其中生成若干个 part_XXXX.bin 文件。

主要功能：

按指定的总大小和分块大小创建文件
文件名格式为 part_0000.bin、part_0001.bin、……
如果总大小不能整除分块大小：
part_0000.bin 为余数大小
后续文件都是统一的标准 chunk 大小
默认在当前命令行所在目录下创建数据集目录
支持可选的数据集目录名
支持 single / double 两种 accounting mode
2. dummy_dataset_release.sh

用于从已有的 dummy dataset 中释放空间。

主要功能：

自动扫描数据集目录中的 part_*.bin 文件
自动推断当前的标准 chunk 大小
先列出当前目录下的文件情况，方便确认
在终端中询问“要释放几个 chunk”
按编号从大到小删除对应数量的 chunk 文件
支持 single / double 两种 accounting mode
如果不传路径，默认操作当前目录下的 ./dummy-dataset
为什么需要这两个脚本

在一些集群或并行文件系统环境中，直接手写大文件做占空间测试比较麻烦，而且删除时也不方便控制释放粒度。

这两个脚本的设计目标是：

创建时方便：快速生成指定规模的数据集
释放时方便：可以按 chunk 为单位删除文件，逐步释放空间
结构清晰：文件命名规则固定，便于查看和管理
为什么这里会出现“2 倍占用”

在当前机器环境里，我们观察到这样一个现象：

例如创建名义上的 1G chunk
ls -lh 看到的文件大小可能接近 1.0G
但 du -sh 统计出来的实际占用可能接近 2.0G

这不是脚本本身重复写入了两份数据，而更可能是底层文件系统的空间分配 / 计费方式导致的。

更准确地说：

du 默认统计的是实际分配出去的空间
du --apparent-size 统计的是文件的表观大小
在并行文件系统、集群存储或特殊配额环境下，一个文件真正占掉多少空间，可能不等于它表面上显示出来的文件大小
因此，可能会出现“表面 1 份、实际按 2 份算”的现象

所以这里 README 里统一采用如下表述：

在当前环境中，dummy dataset 的实际磁盘占用经常接近表观大小的 2 倍，因此脚本默认提供 double 模式来适配这种情况。

请注意：

这个“2 倍”是当前环境下的经验现象
不是所有文件系统都会这样
如果换一台机器、换一个文件系统，比例可能就不是 2 倍了
Accounting Mode 说明

两个脚本都支持两种模式：

double（默认）

适用于当前这个“du 看起来约为 2 倍”的环境。

含义是：

你输入的大小，表示你希望最终占用掉的空间
脚本会按“2 倍环境”做折算
例如你希望每个 chunk 最终占用约 1G
脚本就会实际创建更小的文件，以便在当前环境下最终显示为接近 1G

这个模式主要是为了让脚本输入更符合直觉。

single

适用于普通 1 倍环境。

含义是：

输入多少，就按多少创建
不做额外折算

如果将来换到一个普通文件系统，通常可以用这个模式。

创建脚本用法
基本格式
sh dummy_dataset_create.sh <TOTAL_SIZE> <CHUNK_SIZE> [DATASET_NAME] [single|double]
参数说明
TOTAL_SIZE
希望创建的数据集总大小
CHUNK_SIZE
希望每个标准 chunk 对应的大小
DATASET_NAME
可选，数据集目录名
默认值：dummy-dataset
single|double
可选，accounting mode
默认值：double
示例 1
sh dummy_dataset_create.sh 10G 1G

表示：

总目标大小：10G
每个 chunk：1G
数据集目录名：默认 dummy-dataset
模式：默认 double

效果：

在当前目录创建 ./dummy-dataset
生成若干个 part_XXXX.bin
在当前环境中，最终磁盘占用通常会接近目标值
示例 2
sh dummy_dataset_create.sh 105G 10G my-dataset

表示：

总目标大小：105G
chunk 大小：10G
数据集目录名：my-dataset
模式：默认 double

如果存在余数，则：

part_0000.bin 为较小的余数块
后续 part_0001.bin ~ ... 都是标准 chunk
示例 3
sh dummy_dataset_create.sh 10G 1G my-dataset single

表示：

在 single 模式下创建
更适合普通文件系统环境
释放脚本用法
基本格式
sh dummy_dataset_release.sh [DATASET_PATH] [single|double]
参数说明
DATASET_PATH
可选，要释放的数据集路径
默认值：./dummy-dataset
single|double
可选，accounting mode
默认值：double
示例 1
sh dummy_dataset_release.sh

表示：

释放当前目录下的 ./dummy-dataset
使用默认 double 模式
示例 2
sh dummy_dataset_release.sh ./my-dataset

表示：

释放 ./my-dataset
使用默认 double 模式
示例 3
sh dummy_dataset_release.sh ./my-dataset single

表示：

释放 ./my-dataset
使用 single 模式估算释放空间
释放脚本的工作逻辑

释放脚本会按以下流程执行：

扫描目录中的 part_*.bin
自动推断标准 chunk 大小
打印当前文件列表的前几行
提示输入要释放几个 chunk
显示将要删除的文件
询问是否确认删除
删除编号最大的若干个 chunk 文件

这样做的好处是：

不容易误删
删除过程可控
释放粒度稳定
典型目录结构示例

例如一个 105G / 10G 的数据集可能长这样：

dummy-dataset/
├── part_0000.bin   # 5G remainder
├── part_0001.bin   # 10G chunk
├── part_0002.bin   # 10G chunk
├── part_0003.bin   # 10G chunk
├── ...
└── part_0010.bin   # 10G chunk

释放时如果输入 2，脚本通常会优先删除：

part_0010.bin
part_0009.bin

这样可以保持剩余结构整齐，也方便继续释放。

常见注意事项
1. 为什么文件看起来是 1G，但 du 是 2G？

这是当前环境的空间分配/计费特性导致的现象，不代表脚本创建了两份数据。

2. 为什么默认用 double？

因为当前机器上最常见的观察结果是：

du 统计的实际占用大约是表面大小的 2 倍

所以默认模式直接按这个经验值处理，使用起来更顺手。

3. 如果换了环境怎么办？

如果换到普通文件系统，发现不再有 2 倍现象，就可以改用：

single

模式。

4. 为什么不直接用一个大文件？

因为后续释放空间时，一个大文件只能整块删除，不方便逐步释放。拆成多个 chunk 后更灵活。

推荐使用方式

如果你当前就在这个相同的集群环境里，通常直接用默认模式即可：

sh dummy_dataset_create.sh 100G 10G
sh dummy_dataset_release.sh

如果你已经知道当前环境不是 2 倍计费，可以手动改成：

sh dummy_dataset_create.sh 100G 10G single
sh dummy_dataset_release.sh ./dummy-dataset single
总结

这两个脚本的目标不是生成“真实数据”，而是生成一个：

结构清晰
容易控制
便于逐步释放
适合集群磁盘测试

的 dummy dataset。

其中 double 模式是为了适配当前环境中经常出现的“实际占用约 2 倍”现象，方便大家在这个环境下更直观地控制目标占用空间。

-------------------------------------------------------------------------------
新增：inode 版本脚本（dummy_idataset_*.sh）

除了按空间占用的 dummy dataset，这里还提供一套按 inode 占用的脚本：

1. dummy_idataset_create.sh
2. dummy_idataset_release.sh

这套脚本的目标是“消耗 inode 数量”，而不是消耗文件内容大小。适用于 inode 配额测试、文件数限制测试。

重要说明：

- idataset 脚本不支持 single / double 参数
- 输入多少 inode 目标，就按该目标创建
- 建议用 `df -i` 查看 inode 使用变化

dummy_idataset_create.sh 用法

基本格式：

sh dummy_idataset_create.sh <TOTAL_INODES> <CHUNK_INODES> [DATASET_NAME]

参数说明：

- TOTAL_INODES：目标 inode 总占用
- CHUNK_INODES：每个可释放 chunk 对应的 inode 单位
- DATASET_NAME：可选，目录名，默认 `dummy-idataset`

行为说明：

- 创建目录结构：`chunk_0000`、`chunk_0001`、...
- 在每个 chunk 下创建 `inode_000000.dat`、`inode_000001.dat`、...
- 每个 chunk 的 inode 单位计算方式：
  1 个目录 inode + (N-1) 个文件 inode = N
- 若总量不能整除 chunk：
  `chunk_0000` 作为 remainder，小于标准 chunk

示例：

sh dummy_idataset_create.sh 1M 100K
sh dummy_idataset_create.sh 200K 20K my-idataset

dummy_idataset_release.sh 用法

基本格式：

sh dummy_idataset_release.sh [DATASET_PATH]

参数说明：

- DATASET_PATH：可选，默认 `./dummy-idataset`

行为说明：

- 自动扫描 `chunk_XXXX`
- 自动推断标准 chunk inode 单位
- 交互询问释放几个 chunk
- 从大编号向前删除（通常会保留 remainder 的 `chunk_0000`）

示例：

sh dummy_idataset_release.sh
sh dummy_idataset_release.sh ./my-idataset

推荐检查命令：

df -i .
find ./dummy-idataset -type f | wc -l
