# HDFS指北

## 一、认知定位（Why & What：明确 HDFS 的价值与核心）

### 1. 背景与起源

- **问题驱动**：随着大数据时代到来，单机文件系统面临三大痛点：
  - ①海量数据（TB/PB 级）无法存储；
  - ②单点故障导致数据可靠性低；
  - ③跨节点数据访问效率差。

- **起源**：2003 年 Google 发表《Google File System》（GFS）论文，为分布式存储提供理论原型；2006 年 Apache Hadoop 项目基于 GFS 思想实现 HDFS（Hadoop Distributed File System），解决大规模数据的分布式存储与高可靠问题。
- **核心目标**：支持 “一次写入、多次读取” 的大文件（GB/TB 级）存储，适配大数据计算（如 MapReduce、Spark）的流式数据访问场景。

### 2. 核心抽象

HDFS 的核心模型是**主从（Master/Slave）架构**，抽象为三大组件：

- **NameNode（主节点）**：管理元数据（目录结构、文件 - 块映射、块的副本位置），不存储实际数据，是 “大脑”。
- **DataNode（从节点）**：存储实际数据块（默认 128MB / 块，Hadoop 2.x+），定期向 NameNode 发送心跳（默认 3 秒）汇报状态，是 “手脚”。
- **SecondaryNameNode（辅助节点）**：非 NameNode 备份，仅负责合并 NameNode 的 edits log（元数据变更日志）与 fsimage（元数据快照），减轻 NameNode 负担。

### 3. 哲学与定位

- **生态定位**：HDFS 是大数据生态的 “底层存储基石”，为 MapReduce、Spark、Hive、HBase 等计算 / 查询引擎提供统一数据存储服务。

- 对比定位：

  | 存储系统       | 优势                 | 劣势                  | 适配场景               |
  | -------------- | -------------------- | --------------------- | ---------------------- |
  | HDFS           | 大文件存储、高可靠   | 小文件低效、随机写差  | 大数据批处理、日志存储 |
  | 本地文件系统   | 随机读写快           | 无分布式能力          | 单机应用               |
  | 对象存储（S3） | 支持小文件、弹性扩展 | 流式读取效率低于 HDFS | 云原生数据存储         |

## 二、原理支撑（How - Theory 简述）

### 1. 体系结构：组成部分与整体关系

#### 1.1 经典架构（非 HA 模式）

- **NameNode (NN)：主节点**
  - 职责：管理文件系统**命名空间**（目录树、文件元数据、块列表等），所有元数据存储在内存中。
  - 存储文件：
    - `fsimage`（元数据镜像文件）
    - `edits`（操作日志）
  - 启动流程：NN 加载 `fsimage` 到内存，并重放 `edits` 日志，恢复最终状态。
- **Secondary NameNode (2NN)：检查点节点**
  - 职责：定期拉取 NN 的 `fsimage` 与 `edits`，合并后生成新的 `fsimage`，再推送回 NN。
  - 目的：缩短 NN 重启时间，防止 `edits` 无限增长。
  - 注意：它**不是热备节点**，不能实现高可用。
- **DataNode (DN)：存储节点**
  - 职责：负责数据块存储与管理。
  - 心跳机制：周期性向 NN 发送心跳与块报告，汇报存活与块分布情况。

#### 1.2 高可用架构（HA 模式）

- **Active NameNode & Standby NameNode**
  - Active NN：处理客户端请求。
  - Standby NN：实时同步 Active 的元数据，随时可切换。
- **JournalNodes (JNs)**
  - 职责：持久化 edits log，保证元数据同步。
  - Active NN 写日志 → 多数 JN 持久化 → Standby NN 从 JN 拉取更新。
- **ZooKeeper (ZK)**
  - 职责：
    - 故障检测与转移
    - 领导者选举（保证只有一个 Active NN）
- **ZooKeeper Failover Controller (ZKFC)**
  - 部署：每个 NN 上独立进程。
  - 职责：
    - 健康监测 NN
    - 维护 ZK 上的临时节点
    - 参与 Active/Standby 切换

------

### 2. 核心机制：内部运行方式、关键原理

#### 2.1 文件传输机制

##### 2.1.1 写文件流程

- **非 HA 模式**
  - Client → NN 请求创建文件，NN 校验合法性。
  - Client 申请块与副本位置，NN 分配（机架感知策略）。
  - Client 建立管道 `Client→DN1→DN2→DN3`，写入数据包（64KB）。
  - 所有 DN 返回 ACK，数据落盘并生成 `.blk` 与 `.meta` 文件。
  - DN 上报完成 → NN 更新元数据（写入 edits log、本地内存）。
  - Client 调用 `close()` 完成。
- **HA 模式**
  - Active NN：执行上述所有操作，并将 edits log 写入 JN。
  - Standby NN：从 JN 拉取最新日志，重放操作，保证状态一致。
  - Client：始终与 Active NN 交互（ZKFC 确保唯一 Active）。

##### 2.1.2 读文件流程

- **非 HA 模式**
  - Client 向 NN 查询元数据，获取块位置与副本列表。
  - Client 选择最近 DN 读取数据，校验与恢复损坏块。
  - Client 拼接所有块，完成文件读取。
- **HA 模式**
  - Client 可同时向 Active/Standby 查询元数据。
  - 其余流程与非 HA 一致。

------

#### 2.2 元数据保存机制

##### 2.2.1 内存镜像（In-Memory Image）

- **非 HA 模式**：NN 内存中存全量元数据。
- **HA 模式**：Active 与 Standby 各自维护镜像，Standby 通过 JN 同步更新。

##### 2.2.2 编辑日志（edits log）

- **非 HA 模式**：存本地，路径由 `dfs.namenode.edits.dir` 决定。
- **HA 模式**：Active NN 写入 JN，Standby NN 从 JN 拉取。

##### 2.2.3 镜像快照（fsimage）

- **非 HA 模式**：由 2NN 周期合并日志生成快照。
- **HA 模式**：由 Standby NN 完成 checkpoint，并推送到 Active NN。

------

#### 2.3 宕机恢复机制

##### 2.3.1 Active NameNode 宕机（HA 模式）

- ZKFC 检测 NN 宕机 → 删除临时节点。
- Standby ZKFC 竞选成功 → 成为主控。
- Fencing 隔离原 Active（如 kill -9、关闭 RPC）。
- Standby NN 拉取 JN 最新日志，切换为 Active。
- 整个过程约 < 10 秒。

##### 2.3.2 DataNode 宕机

- NN 检测心跳超时 → 标记为死亡。
- NN 触发副本复制，保证块数。
- 未完成块标记为无效。

##### 2.3.3 JournalNode 宕机

- NN 检测心跳超时 → 标记故障。
- Active NN 写日志需多数成功；Standby 从健康 JN 读取。
- 故障 JN 恢复后自动追赶缺失日志。

------

#### 2.4 集群扩缩容机制

##### 2.4.1 新增 DataNode

- 新节点安装 Hadoop，配置 core-site/hdfs-site，保证免密与时间同步。
- 启动 DN → 主动注册到 NN。
- NN 调用 Balancer 做数据均衡。

##### 2.4.2 减少 DataNode

- 在 `dfs.hosts.exclude` 配置节点 → 执行 `-refreshNodes`。
- NN 触发数据迁移，完成后标记退役。
- 强制退役需确认副本充足。

------

#### 2.5 HA 模式下 NameNode 同步

- **实时同步**：Active 写日志到 JN → Standby 从 JN 拉取。
- **定期同步**：Standby 定期 checkpoint 并推送 fsimage 给 Active。
- **额外同步**：
  - DN 心跳：同时汇报给两 NN。
  - 块汇报：定期发给两 NN。
  - 配置更新：需手动在两 NN 同步。

------

#### 2.6 心跳机制

##### 2.6.1 心跳交互

| 交互双方            | 频率 | 内容                         | 异常处理                             |
| ------------------- | ---- | ---------------------------- | ------------------------------------ |
| DataNode → NameNode | 3s   | 节点状态、磁盘使用率、块状态 | 超时 → 标记死亡；触发副本修复        |
| JournalNode → NN    | 5s   | 健康状态、事务 ID 范围       | 超时 → 标记故障；读写跳过故障节点    |
| ZKFC → ZooKeeper    | 2s   | NN 健康、ZKFC 角色           | 心跳消失 → ZK 删除临时节点，触发选主 |

##### 2.6.2 优化建议

- 大集群（1000+ DN）可调 `dfs.heartbeat.interval=5`，降低 NN 压力。
- 网络抖动时，将超时调至 600s，避免误判。

------

### 3. 知识模型：抽象与建模方式

- **命名空间模型**：树形目录结构，映射到块 ID。
- **数据块模型**：文件切分为固定大小块（默认 128MB），每块多副本存储。
- **日志模型**：写前日志（WAL）保障一致性。
- **主备模型**：Active/Standby NN 通过 JN 保持强一致性。

------

### 4. 数据/信息流转：逻辑链条

- **写流程（HA 模式）**
   Client → Active NN → JN → Standby NN → DN（Pipeline）
- **读流程（HA 模式）**
   Client → 任意 NN 查询元数据 → DN 读取副本 → Client 拼接
- **元数据流转**
   Active NN → edits log → JN → Standby NN → checkpoint → Active NN
- **状态流转**
   DN 心跳/块汇报 → Active/Standby NN
   ZKFC ↔ ZooKeeper → NN 状态切换

## 二、原理支撑（How - Theory 详述）
### 1. 体系结构：组成部分与整体关系
HDFS 采用“主从（Master/Slave）”架构设计，核心组件分为管理节点与存储节点，根据是否支持高可用（HA），架构分为非 HA 模式与 HA 模式两类。

#### 1.1 非 HA 模式（经典架构）
非 HA 模式为基础架构，存在单点故障风险（NameNode 故障会导致集群不可用），核心组件包括 1 个 NameNode、1 个 Secondary NameNode 及多个 DataNode。

##### 1.1.1 NameNode（NN，主节点）
- 定位：集群唯一的元数据管理者，无备用节点。
- 核心职责：
  1. 管理文件系统**命名空间（Namespace）**：维护目录树结构（如 /user/data）、文件元数据（文件名、权限、副本数、文件与块的映射关系）。
  2. 内存化存储元数据：所有元数据加载到内存，支撑毫秒级查询与操作响应（性能核心）。
  3. 管理 DataNode 集群：接收 DataNode 心跳与块报告，维护“可用 DataNode 列表”与“块副本位置信息”。
- 持久化文件：本地磁盘存储两类关键文件，确保元数据不丢失：
  - `fsimage`：元数据镜像文件，存储某一时刻的全量元数据快照（如文件-块映射、目录结构）。
  - `edits`：编辑日志文件，记录所有元数据变更操作（如创建文件、删除目录、修改副本数），遵循“写前日志（WAL）”原则（先写日志再更新内存，防止内存数据丢失）。

##### 1.1.2 Secondary NameNode（2NN，辅助节点）
- **关键提醒**：并非 NameNode 的热备节点，无法在 NN 故障时接管集群，仅用于辅助 NN 优化元数据管理。
- 核心职责：
  1. 定期合并 `fsimage` 与 `edits`：按配置触发合并（默认触发条件：①每 3600 秒（1 小时）；② `edits` 日志大小达 64MB），生成新的 `fsimage` 并推送给 NN。
  2. 优化 NN 重启效率：减少 NN 重启时需重放的 `edits` 日志量（原需重放全部日志，合并后仅需重放最新小部分），缩短重启时间。
  3. 防止 `edits` 无限膨胀：避免日志文件过大导致磁盘占满或读写效率下降。

##### 1.1.3 DataNode（DN，从节点）
- 定位：集群的实际数据存储节点，数量可动态扩展（从几十到数千个）。
- 核心职责：
  1. 存储数据块（Blocks）：将文件按固定大小（默认 128MB，可配置）拆分为块，每个块存储为本地磁盘文件（如 `.blk` 格式），并生成对应的校验和文件（`.meta`，用于数据完整性校验）。
  2. 汇报节点状态：
     - 心跳（Heartbeat）：每 3 秒向 NN 发送心跳，报告节点存活状态与磁盘使用率（NN 据此判断 DN 是否“存活”）。
     - 块报告（BlockReport）：每 6 小时向 NN 发送块报告，汇报本地存储的所有块列表（NN 据此更新“块副本位置映射”）。
  3. 执行数据操作：接收客户端或其他 DN 的数据读写请求，完成数据存储、转发（如副本复制）与删除。

#### 1.2 HA 模式（高可用架构）
为解决非 HA 模式的 NameNode 单点故障问题，HA 模式引入“双 NameNode 主备”“JournalNodes 共享存储”“ZooKeeper 协调”等组件，确保集群无单点故障。

##### 1.2.1 双 NameNode（Active/Standby NN）
- 定位：2 个 NameNode 形成主备关系，元数据实时同步，确保故障时无缝切换。
  - **Active NameNode**：主节点，处理所有客户端请求（读写文件、元数据变更），是集群的“对外服务入口”。
  - **Standby NameNode**：备节点，不处理客户端请求，仅实时同步 Active NN 的元数据，保持与 Active NN 状态一致（内存镜像、块映射信息完全相同），等待 Active 故障时接管。

##### 1.2.2 JournalNodes（JNs，共享存储集群）
- 定位：HA 模式的核心组件，由**奇数个节点（通常 3 或 5 个）** 组成轻量级集群，提供元数据日志的共享存储服务。
- 核心职责：
  1. 存储 Active NN 的编辑日志：Active NN 不再将 `edits` 日志写入本地磁盘，而是通过 RPC 将所有元数据变更（如创建文件、修改块状态）同步到多数 JN 节点（如 3 个 JN 至少 2 个写入成功），确保日志持久化且无单点丢失。
  2. 向 Standby NN 提供日志读取：Standby NN 持续从 JNs 读取最新 `edits` 日志，并在本地内存中“重放（replay）”这些操作，实时更新自身元数据，确保与 Active NN 状态一致。

##### 1.2.3 ZooKeeper（ZK，分布式协调服务）
- 定位：提供集群节点的故障检测、领导者选举与分布式锁服务，是 HA 模式“自动故障转移”的核心。
- 核心职责：
  1. 故障检测：监控 2 个 NameNode 的健康状态（通过 ZKFC 间接实现）。
  2. 领导者选举：当 Active NN 故障时，协助 Standby NN 快速被选举为新的 Active NN，确保切换自动化。
  3. 临时节点管理：存储 ZKFC 注册的 NameNode 临时节点（Ephemeral Node），节点存在表示对应 NN 健康，节点消失表示 NN 故障。

##### 1.2.4 ZKFC（ZooKeeper Failover Controller，故障转移控制器）
- 定位：运行在每个 NameNode 节点上的独立进程，是 NameNode 与 ZooKeeper 之间的“通信桥梁”。
- 核心职责：
  1. 健康监测：每 1 秒向本地 NameNode 发送健康检查请求（如检查 NN 进程是否存活、RPC 端口是否可用），持续判断 NN 状态。
  2. Session 管理：在 ZooKeeper 上为本地 NN 注册一个临时节点，若 NN 健康，临时节点保持存在；若 NN 故障或 ZKFC 自身故障，ZK 会话超时导致临时节点删除，触发故障转移。
  3. 领导者选举与隔离：当检测到 Active NN 故障时，向 ZK 申请分布式锁，申请成功后执行“隔离原 Active NN”操作（如 kill 原 NN 进程、关闭其 RPC 端口，防止“双活”冲突），并通知本地 Standby NN 切换为 Active 状态。

#### 1.3 核心组件关系图
- 非 HA 模式：`Client` ↔ `NameNode` ↔ `DataNode 集群`；`Secondary NameNode` 定期与 `NameNode` 交互（拉取并合并元数据文件）。
- HA 模式：`Client` ↔ `Active NameNode` ↔ `JournalNodes 集群` ↔ `Standby NameNode`；`ZKFC（每 NN 节点 1 个）` ↔ `ZooKeeper 集群`（监控 NN 并参与选主）；`DataNode 集群` 同时向 2 个 NN 发送心跳与块报告。


### 2. 核心机制：内部运行方式、关键原理
HDFS 的核心机制围绕“数据读写”“元数据管理”“故障恢复”“节点伸缩”展开，需重点区分 HA 与非 HA 模式的差异。

#### 2.1 文件传输机制：读写流程与性能优化
文件传输是 HDFS 的核心功能，读写流程需结合元数据管理与副本策略，HA 与非 HA 模式的关键差异集中在“元数据处理节点”与“日志存储位置”。

##### 2.1.1 写文件完整流程（区分 HA 与非 HA）
HDFS 写文件采用“管道（Pipeline）传输”与“副本同步”机制，确保数据可靠性（多副本）与传输效率（并行转发）。

- 非 HA 模式写流程
  1. 客户端初始化：Client 调用 `FileSystem.create()` 方法，通过 RPC 向 **NameNode** 申请创建文件；NN 校验客户端权限（如是否有写目录权限）、检查路径合法性（如文件是否已存在），校验通过后返回“可写标识”与文件唯一 ID。
  2. 块申请与副本位置分配：Client 按块大小（默认 128MB）在本地缓存数据，当缓存满一块时，向 NN 申请“块 ID + 副本存储位置”；NN 基于“机架感知策略”分配 3 个副本位置（如：机架 1 的 DN1、机架 2 的 DN2、机架 2 的 DN3，兼顾容错与网络效率）。
  3. 管道（Pipeline）建立：Client 与第一个副本节点（如 DN1）建立 TCP 连接（默认端口 50010），DN1 再与第二个副本节点（DN2）建立连接，DN2 与第三个副本节点（DN3）建立连接，形成 `Client→DN1→DN2→DN3` 的数据传输管道；所有 DN 向 Client 返回“准备就绪”确认信号。
  4. 数据传输与 ACK 确认：Client 将数据切分为 64KB 的“数据包（Packet）”，按顺序写入管道；每个 DN 接收数据包后，先写入本地临时文件（`.blk.tmp`），再转发给下一个 DN，同时向 Client 发送“ACK 确认”（表示数据包已接收并存储）；若某 DN 故障（如 DN2 宕机），Client 立即断开与 DN2 的连接，重新建立 `Client→DN1→DN3` 的管道，已传输到 DN1 的数据包无需重传（仅补传未完成部分）。
  5. 块完成与元数据更新：当前块的所有数据包传输完成后，Client 发送“块结束信号”；DN1、DN3 将临时文件重命名为正式块文件（`.blk`），并生成校验和文件（`.meta`）；DN1、DN3 向 NN 汇报“块完成”，NN 更新元数据（将“文件-块映射”“块-副本位置”写入内存），同时将该变更记录到本地 `edits` 日志（持久化）。
  6. 文件关闭：Client 调用 `FileSystem.close()` 方法，NN 标记文件为“关闭状态”（禁止后续写入），并将最终元数据快照更新到 `fsimage`（非实时，需等待 2NN 合并）。

- HA 模式写流程（与非 HA 差异点）
  - 差异 1：元数据处理节点唯一。Client 仅向 **Active NameNode** 发送请求（Standby NameNode 不处理写请求），避免双节点竞争。
  - 差异 2：编辑日志存储位置变更。Active NN 不将 `edits` 日志写入本地磁盘，而是通过 RPC 同步到 **JournalNodes 集群**（需多数 JN 写入成功，如 3 个 JN 至少 2 个成功），确保日志无单点丢失。
  - 差异 3：元数据实时同步。Standby NN 持续从 JNs 读取最新 `edits` 日志，在本地内存中重放操作，实时更新自身元数据（与 Active NN 保持一致），无需等待 2NN 合并（HA 模式下 2NN 不再参与元数据合并）。
  - 其他流程（管道建立、数据传输、ACK 确认、块完成）与非 HA 模式完全一致。

##### 2.1.2 读文件完整流程（区分 HA 与非 HA）
HDFS 读文件采用“就近读取”与“缓存优化”策略，优先读取距离客户端最近的副本（如本地节点、同机架节点），减少跨网络传输。

- 非 HA 模式读流程
  1. 元数据查询：Client 调用 `FileSystem.open()` 方法，通过 RPC 向 **NameNode** 发送请求，获取“文件的块列表”与“每个块的副本位置列表”；NN 按“客户端与 DN 的网络距离”排序副本（优先级：本地 DN > 同机架 DN > 跨机架 DN），优先返回最近的副本位置。
  2. 数据读取与校验：Client 选择最近的 DN（如本地 DN）建立 TCP 连接（默认端口 50010），发送“块读取请求”（含块 ID 与读取偏移量）；DN 读取本地块文件（`.blk`）与校验和文件（`.meta`），计算当前数据的校验和并与 `.meta` 中的校验和对比，若不匹配（数据损坏），DN 返回“数据损坏”提示，Client 自动切换到其他副本 DN 重新读取；Client 在本地缓存已读取的块数据（默认开启缓存，缓存大小通过 `fs.local.block.size` 配置），后续读取同一块时直接使用缓存，无需再次请求 DN。
  3. 多块拼接与文件完成：Client 按块顺序依次读取所有块，在本地内存中拼接成完整文件；读取完成后关闭与 DN 的连接；NN 元数据默认缓存 10 分钟，若 Client 再次读取同一文件，可直接使用本地元数据缓存，避免重复查询 NN。

- HA 模式读流程（与非 HA 差异点）
  - 核心差异：元数据查询节点可多选。Client 可向 **Active NameNode 或 Standby NameNode** 发送读请求（两者元数据实时同步，状态一致），分散 NN 的读压力；其他流程（数据读取、校验、缓存）与非 HA 模式完全一致。

#### 2.2 元数据保存机制：确保元数据不丢失、可恢复
元数据（目录结构、文件-块映射、块-副本位置）是 HDFS 的“大脑”，其保存机制直接决定集群稳定性，HA 与非 HA 模式的核心差异在于“日志存储方式”与“同步逻辑”。

##### 2.2.1 内存镜像（In-Memory Image）
内存镜像是元数据的“运行时载体”，所有元数据操作均基于内存，确保高性能。

- 非 HA 模式
  - 存储内容：全量元数据（目录树、文件元数据、块-副本映射），仅 NameNode 维护 1 份内存镜像。
  - 持久化依赖：内存镜像不直接持久化到磁盘，需依赖 `fsimage`（全量快照）与 `edits`（增量日志）恢复；NN 重启时，先加载 `fsimage` 到内存，再重放 `edits` 中的所有操作，恢复到最新状态。
  - 关键配置：内存大小通过 `HADOOP_NAMENODE_OPTS=-Xmx<size>` 配置（如 1000 万文件需 10GB 内存，避免内存溢出）。

- HA 模式
  - 存储内容：Active NN 与 Standby NN 各维护 1 份独立的内存镜像，内容完全一致（含目录树、文件元数据、块-副本映射）。
  - 同步逻辑：Standby NN 通过持续读取 JournalNodes 中的 `edits` 日志，在本地内存中重放操作，实时更新内存镜像（确保与 Active NN 同步延迟 < 1 秒）。
  - 优势：Active NN 故障时，Standby NN 可直接使用本地内存镜像提供服务，无需重新加载 `fsimage` 与重放日志，缩短切换时间。

##### 2.2.2 编辑日志（edits log）
编辑日志是元数据变更的“增量记录”，遵循“写前日志”原则，确保元数据变更可追溯、不丢失。

- 非 HA 模式
  - 存储位置：NameNode 本地磁盘（路径由 `dfs.namenode.edits.dir` 配置，建议配置多磁盘，避免单点故障）。
  - 记录内容：所有元数据变更操作（如创建/删除文件、修改副本数、添加/删除块），每条记录含“事务 ID（TxID）”“操作类型”“操作内容”（如 TxID=1001，类型=创建文件，路径=/user/data.txt）。
  - 滚动机制：当 `edits` 日志大小达配置阈值（默认 64MB）或时间达阈值（默认 1 小时），触发日志滚动（生成新的 `edits` 文件，旧文件保留用于合并）。

- HA 模式
  - 存储位置：JournalNodes 集群（路径由 `dfs.namenode.shared.edits.dir=qjournal://jn1:8485;jn2:8485;jn3:8485/mycluster` 配置，`8485` 为 JN 默认端口）。
  - 写入逻辑：Active NN 每次元数据变更后，通过 RPC 将 `edits` 日志条目发送到所有 JN；仅当“超过半数 JN 写入成功”（如 3 个 JN 至少 2 个成功），Active NN 才认为日志持久化完成，再更新本地内存镜像（确保数据可靠性）。
  - 分段存储：JN 按“事务 ID 范围”分段存储 `edits` 日志（默认每 64MB 切分一个文件），便于 Standby NN 增量读取与故障 JN 恢复。

##### 2.2.3 镜像快照（fsimage）
镜像快照是元数据的“全量快照”，用于缩短 NN 重启时间，减少 `edits` 日志体积。

- 非 HA 模式
  - 生成主体：Secondary NameNode（2NN）。
  - 生成触发条件：
    1. 时间触发：每 3600 秒（1 小时，由 `dfs.namenode.checkpoint.period` 配置）。
    2. 日志大小触发：`edits` 日志累计事务数达 100 万（由 `dfs.namenode.checkpoint.txns` 配置）。
  - 生成流程：2NN 从 NN 拉取当前 `fsimage` 与 `edits`，在本地合并（将 `edits` 中的变更应用到 `fsimage`），生成新的 `fsimage`，再将新 `fsimage` 推送给 NN；NN 替换旧 `fsimage`，并清空 `edits` 日志（保留旧日志备份）。

- HA 模式
  - 生成主体：Standby NameNode（HA 模式下 2NN 不再参与合并）。
  - 生成触发条件：与非 HA 模式一致（时间或日志大小触发）。
  - 生成流程：Standby NN 从 JournalNodes 拉取所有未合并的 `edits` 日志，与本地 `fsimage` 合并生成新 `fsimage`；新 `fsimage` 同步到 Active NN（确保两者 `fsimage` 版本一致）；合并完成后，Standby NN 通知 JNs 删除已合并的旧 `edits` 日志（释放磁盘空间）。

##### 2.2.4 HA 模式元数据更新完整流程
```
Active NN 接收客户端元数据变更请求（如创建文件）
→ Active NN 校验请求合法性（权限、路径）
→ Active NN 生成 `edits` 日志条目（含事务 ID）
→ Active NN 通过 RPC 将 `edits` 发送到 JournalNodes 集群
→ 超过半数 JN 写入 `edits` 成功并返回确认
→ Active NN 更新本地内存镜像（应用该变更）
→ Standby NN 定期（默认 100ms/次）从 JNs 读取新 `edits` 日志
→ Standby NN 在本地内存中重放 `edits` 日志，更新自身内存镜像
→ 满足 Checkpoint 条件时，Standby NN 合并 `fsimage` 与 `edits`，生成新 `fsimage`
→ Standby NN 将新 `fsimage` 同步到 Active NN，两者 `fsimage` 版本统一
```

#### 2.3 宕机恢复机制：保障集群高可用、数据不丢失
HDFS 针对不同组件（NameNode、DataNode、JournalNode）的宕机场景，设计了差异化的恢复策略，核心目标是“快速恢复服务”与“无数据丢失”。

##### 2.3.1 Active NameNode 宕机（HA 模式核心场景）
HA 模式通过“自动故障转移”机制，确保 Active NN 宕机后 < 10 秒恢复服务，无人工干预。

1. 故障检测：Active NN 节点上的 ZKFC 每 1 秒向本地 NN 发送健康检查请求（如检查 NN 进程是否存活、RPC 端口是否响应）；若连续 3 次未收到 NN 响应，ZKFC 判定 Active NN 宕机，立即删除自身在 ZooKeeper 上注册的“临时节点”。
2. 选主触发：Standby NN 节点上的 ZKFC 实时监控 ZooKeeper 中的临时节点，当检测到“Active NN 临时节点消失”，立即向 ZK 申请分布式锁（抢占“主节点”资格）；若申请成功，该 ZKFC 成为“主 ZKFC”。
3. Fencing（隔离原 Active NN）：主 ZKFC 执行“隔离操作”，防止原 Active NN 恢复后出现“双活”冲突（双 Active 会导致元数据不一致），常用隔离手段：
   - 执行 `kill -9 <NN 进程 ID>`，强制杀死原 Active NN 进程。
   - 关闭原 Active NN 的 RPC 端口（如 50070 管理端口、9000 服务端口），禁止其接收客户端请求。
   - 极端场景（如原 NN 进程无法杀死）：格式化原 NN 的元数据目录（需确保 Standby NN 元数据完整，谨慎使用）。
4. Standby 切换为 Active：主 ZKFC 向本地 Standby NN 发送“切换指令”；Standby NN 从 JournalNodes 读取所有未合并的 `edits` 日志，最后一次更新本地内存镜像（确保元数据最新）；Standby NN 改状态为“Active”，并在 ZooKeeper 上注册新的临时节点；Active NN 向所有 DataNode 发送“地址更新通知”（告知 DN 新 Active NN 地址）；新 Active NN 开始接收客户端读写请求，故障转移完成。

##### 2.3.2 DataNode 宕机（通用场景）
DataNode 宕机不会导致集群不可用，仅需修复其存储的块副本，确保数据可靠性。

1. 故障检测：NameNode 每 3 秒接收 DataNode 心跳；若超过 `dfs.namenode.heartbeat.recheck-interval`（默认 300 秒，5 分钟）未收到某 DN 的心跳，NN 标记该 DN 为“死亡”，并从“可用 DN 列表”中移除。
2. 块副本修复：NN 扫描该“死亡 DN”上存储的所有块，检查每个块的副本数是否低于配置值（默认 3 个）；对“副本不足的块”，NN 选择健康的 DataNode（优先同机架 DN，减少跨网络传输），触发“副本复制”：健康 DN 从其他存活的副本 DN 读取块数据，生成新副本并存储；修复完成后，NN 更新“块-副本位置映射”，标记原“死亡 DN”上的块为“无效”（不再用于读取）。
3. 数据一致性保障：DN 宕机前已完成的块均通过校验和验证（`.meta` 文件），且副本存储在不同机架（容错设计），无数据丢失；未完成的临时块（`.blk.tmp`）被标记为“无效”，不参与后续读取，无需修复。

##### 2.3.3 JournalNode 宕机（HA 模式场景）
JournalNode 采用“多数派容错”设计，单个 JN 宕机不影响集群服务，仅需重启恢复即可。

1. 故障检测：NameNode（Active/Standby）每 5 秒向 JournalNodes 发送心跳；若超过 `dfs.qjournal.write-timeout.ms`（默认 60 秒）未收到某 JN 的响应，NN 标记该 JN 为“故障”。
2. 读写容错：
   - 写操作（Active NN 写 `edits`）：仅需“超过半数 JN 写入成功”（如 3 个 JN 至少 2 个成功），即可认为写操作完成，故障 JN 不影响写服务。
   - 读操作（Standby NN 读 `edits`）：Standby NN 从健康 JN 读取 `edits` 日志，自动跳过故障 JN，不影响元数据同步。
3. 恢复流程：故障 JN 重启后，自动向健康 JN 发送“数据同步请求”，拉取自身缺失的 `edits` 日志（按事务 ID 补全）；补全数据后，JN 向 NN 发送“恢复通知”，重新加入 JN 集群，无需人工干预。

#### 2.4 新增/减少 DataNode 机制：生产扩容/缩容
HDFS 支持动态新增/减少 DataNode，满足业务增长（扩容）或硬件淘汰（缩容）需求，操作过程不影响集群正常服务。

##### 2.4.1 新增 DataNode（扩容）
新增 DataNode 用于扩展集群存储容量与读写并发能力，核心是“节点注册”与“数据均衡”。

1. 前置准备：
   - 在新节点上安装 Hadoop，配置 `core-site.xml`（指定 NameNode 地址，HA 模式需指定 Active/Standby NN 地址）与 `hdfs-site.xml`（指定副本数、块大小、数据存储目录）。
   - 确保新节点与集群所有节点（NN、其他 DN、ZK）实现 SSH 免密通信（避免启动时权限问题）。
   - 配置新节点的 NTP 服务，与集群时间同步（防止因时间差导致心跳异常）。
2. 节点注册流程：
   - 在新节点执行 `hdfs --daemon start datanode`，启动 DataNode 进程。
   - 新 DN 主动向 NameNode 发送“注册请求”，携带节点 ID（首次启动自动生成）、本地磁盘目录、硬件信息（CPU、内存、磁盘大小）。
   - NN 校验新 DN 的配置一致性（如块大小、副本数是否与集群一致），校验通过后将其加入“可用 DN 列表”，并分配块存储任务（如接收其他 DN 迁移的块）。
3. 数据均衡：
   - NN 内置的 Balancer 服务每小时检查集群磁盘使用率（由 `dfs.balancer.period` 配置）。
   - 若新 DN 的磁盘使用率低于集群平均水平（默认差值 > 10%，由 `dfs.balancer.threshold` 配置），Balancer 触发“块迁移”：从高使用率 DN 向新 DN 复制块（迁移带宽默认 1MB/s，由 `dfs.balancer.bandwidthPerSec` 配置，避免影响业务读写）。
   - 数据均衡完成后，新 DN 磁盘使用率与集群平均水平差异 < 10%，扩容结束。

##### 2.4.2 减少 DataNode（缩容，安全退役）
减少 DataNode 需确保其存储的块已迁移到其他 DN，避免数据丢失，核心是“标记退役”与“数据迁移”。

1. 标记退役节点：
   - 在 NameNode 节点的 `hdfs-site.xml` 中配置 `dfs.hosts.exclude` 参数，指定待退役 DN 的 IP 或主机名（如 `<value>/etc/hadoop/exclude.txt</value>`，`exclude.txt` 中每行一个节点地址）。
   - 执行 `hdfs dfsadmin -refreshNodes` 命令，NN 加载 `exclude.txt` 配置，将待退役 DN 标记为“待退役（Decommissioning）”状态；NN 不再向待退役 DN 分配新的块存储任务。
2. 数据迁移：
   - NN 扫描待退役 DN 上的所有块，计算每个块的目标迁移 DN（优先选择同机架健康 DN，减少跨网络传输）。
   - 待退役 DN 向目标 DN 复制块数据，每完成一个块的迁移，向 NN 汇报“块迁移完成”；NN 更新“块-副本位置映射”，标记待退役 DN 上的该块为“无效”。
   - 可通过 NN Web UI（默认端口 50070）的“Decommissioning Nodes”页面查看迁移进度（如已迁移块数、剩余块数）。
3. 退役完成：
   - 待退役 DN 所有块迁移完成后，NN 标记其为“退役完成（Decommissioned）”状态，停止接收其心跳。
   - 在待退役 DN 上执行 `hdfs --daemon stop datanode` 命令，关闭 DataNode 进程。
   - 在 NameNode 的 `exclude.txt` 中删除该节点地址，执行 `hdfs dfsadmin -refreshNodes` 确认退役，缩容结束。
4. 强制退役（不推荐，仅故障场景使用）：
   - 若待退役 DN 故障无法正常启动（无法迁移数据），需先确保其存储的所有块副本数 ≥ 3（避免数据丢失）。
   - 执行 `hdfs dfsadmin -deleteBlockPool <待退役 DN 的节点 ID> <集群 ID>` 命令，删除该 DN 在 NN 中的块池记录（节点 ID 可从 NN Web UI 查看）。
   - 强制退役可能导致数据不一致，需事后通过 `hdfs fsck /` 检查集群数据完整性。

#### 2.5 HA 模式下 NameNode 间的信息交互同步
HA 模式的核心是“双 NN 状态一致”，通过“实时同步（edits 日志）”“定期同步（fsimage）”“额外信息同步”确保两者元数据与节点状态完全一致。

##### 2.5.1 实时同步（edits log 同步）
实时同步是“双 NN 状态一致”的基础，确保 Active NN 的每一次元数据变更都能同步到 Standby NN。

- 触发时机：每发生一次元数据变更（如创建文件、删除块、修改副本数），Active NN 立即触发同步。
- 交互流程：
  1. Active NN 处理客户端元数据变更请求，生成 `edits` 日志条目（含事务 ID、操作内容）。
  2. Active NN 通过 RPC 将 `edits` 日志条目发送到 JournalNodes 集群的所有 JN。
  3. 每个 JN 接收日志后，写入本地磁盘并向 Active NN 返回“写入成功”确认。
  4. Active NN 收到超过半数 JN 的成功确认后，更新本地内存镜像（应用该变更）。
  5. Standby NN 启动“日志拉取线程”，每 100ms 从 JNs 读取新 `edits` 日志（按事务 ID 顺序）。
  6. Standby NN 在本地内存中重放 `edits` 日志（执行相同的元数据变更操作），更新自身内存镜像。
- 一致性保障：JN 按“事务 ID 递增”顺序存储 `edits` 日志，Standby NN 必须按事务 ID 顺序读取并重放（禁止跳号），避免元数据混乱。

##### 2.5.2 定期同步（fsimage 同步）
定期同步用于优化元数据存储（减少 `edits` 日志体积），确保双 NN 的 `fsimage` 版本一致。

- 触发时机：Standby NN 满足 Checkpoint 条件（与非 HA 模式一致）：
  1. 时间触发：每 3600 秒（1 小时，由 `dfs.namenode.checkpoint.period` 配置）。
  2. 日志大小触发：`edits` 日志累计事务数达 100 万（由 `dfs.namenode.checkpoint.txns` 配置）。
- 交互流程：
  1. Standby NN 从 JNs 拉取所有未合并的 `edits` 日志。
  2. Standby NN 将本地 `fsimage` 加载到内存，重放所有未合并的 `edits` 日志，生成新的 `fsimage`（含最新元数据）。
  3. Standby NN 通过 RPC 将新 `fsimage` 发送到 Active NN。
  4. Active NN 接收新 `fsimage` 后，替换本地旧 `fsimage`，并通知 JNs 删除已合并的旧 `edits` 日志（释放磁盘空间）。
- 优势：双 NN 共用同一套 `fsimage`，避免各自维护导致版本差异；Active NN 无需自行合并 `fsimage`，减少 CPU 与磁盘开销。

##### 2.5.3 额外信息同步
除元数据外，双 NN 还需同步“节点状态信息”，确保对集群资源的认知一致。

- DataNode 心跳信息：所有 DataNode 同时向 Active NN 与 Standby NN 发送心跳（每 3 秒 1 次），汇报节点存活状态与磁盘使用率；双 NN 据此维护相同的“可用 DN 列表”。
- DataNode 块报告信息：所有 DataNode 同时向双 NN 发送块报告（每 6 小时 1 次），汇报本地存储的块列表；双 NN 据此维护相同的“块-副本位置映射”，避免某 NN 遗漏块信息。
- 配置变更同步：修改 HDFS 核心配置（如副本数、块大小）后，需在 Active NN 与 Standby NN 节点上同时更新配置文件（`core-site.xml`、`hdfs-site.xml`），并分别执行 `hdfs dfsadmin -refreshConf` 命令，确保双 NN 配置一致（避免因配置差异导致服务异常）。

#### 2.6 心跳机制：集群状态监控核心
心跳机制是 HDFS 感知节点健康状态的“神经末梢”，通过定期心跳实现“故障早发现、早处理”，核心组件间均有独立的心跳交互逻辑。

##### 2.6.1 各组件心跳详情
| 交互双方                | 心跳频率（默认） | 汇报核心内容                                                                 | 异常处理逻辑                                                                 |
| ----------------------- | ---------------- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| DataNode → NameNode     | 3 秒 / 次        | ①节点健康状态（存活/磁盘故障）；②本地磁盘使用率（已用/剩余空间）；③块状态（新增/删除/损坏）；④副本数量是否达标 | ①超过 300 秒未收心跳，标记 DN 为“死亡”；②汇报磁盘故障，触发该 DN 上块的副本修复；③汇报块损坏，标记块“副本不足”并启动复制 |
| JournalNode → NameNode  | 5 秒 / 次        | ①节点健康状态（存活/离线）；②已存储 `edits` 日志的事务 ID 范围（如 TxID 1001~2000）；③读写响应延迟 | ①超过 60 秒未收心跳，标记 JN 为“故障”；②写 `edits` 时跳过故障 JN，读 `edits` 时从健康 JN 获取 |
| ZKFC → ZooKeeper        | 2 秒 / 次        | ①对应 NameNode 的健康状态（健康/故障）；②自身角色（候选节点/主节点）；③会话保持信号 | ①ZKFC 心跳消失，ZK 自动删除其注册的临时节点；②临时节点消失触发 NN 故障转移；③ZK 集群故障时，ZKFC 停止自动切换（防止误操作） |

##### 2.6.2 心跳优化（生产实践）
根据集群规模与网络环境，合理调整心跳参数，平衡“故障检测灵敏度”与“集群资源开销”。

- 大规模集群优化（1000+ DataNode）：
  - 问题：大量 DN 同时发送心跳，会导致 NameNode RPC 压力过大（CPU 占用高、响应延迟增加）。
  - 优化方案：将 DN 心跳频率从 3 秒调整为 5 秒（配置 `dfs.heartbeat.interval=5`），减少心跳次数；同时增大心跳超时阈值（配置 `dfs.namenode.heartbeat.recheck-interval=600`），避免因网络延迟误判 DN 死亡。

- 网络抖动频繁场景优化：
  - 问题：网络不稳定（如跨机房集群）会导致 DN 心跳偶尔丢失，触发不必要的块修复（浪费带宽）。
  - 优化方案：增大心跳超时阈值（如配置 `dfs.namenode.heartbeat.recheck-interval=600`），延长 NN 判定 DN 死亡的时间；同时启用 DN 心跳重试机制（默认已启用），DN 发送心跳失败后自动重试 3 次，减少临时网络问题的影响。

- 高可用优先场景优化（金融、核心业务）：
  - 问题：需快速检测 NN 故障，缩短业务中断时间。
  - 优化方案：将 ZKFC 心跳频率从 2 秒调整为 1 秒（配置 `ha.zookeeper.session-timeout.ms=1000`），加快故障检测速度；同时减小 NN 健康检查间隔（配置 `ha.health-monitor.check-interval.ms=500`），确保 ZKFC 及时发现 NN 故障。


### 3. 知识模型：它是如何抽象和建模的
HDFS 通过“三层抽象”将复杂的分布式存储问题简化，实现“高可靠、高扩展、高性能”的核心目标，抽象模型包括命名空间抽象、数据块抽象、机架感知模型与副本容错模型。

#### 3.1 命名空间抽象（Namespace Abstraction）
- 核心目标：为用户提供“类 Linux 文件系统”的操作体验，屏蔽分布式存储的底层复杂性。
- 抽象逻辑：
  1. 树状目录结构：HDFS 命名空间是一棵分层目录树，与 Linux 文件系统一致（如 `/user/hive/warehouse`），支持目录创建、删除、重命名等操作。
  2. 唯一路径标识：每个文件/目录通过“绝对路径”唯一标识（如 `/data/logs/202405.log`），客户端无需关心文件存储在哪个 DataNode，仅需通过路径访问。
  3. 元数据与数据分离：命名空间仅存储元数据（目录结构、文件属性、文件-块映射），不存储实际数据；实际数据存储在 DataNode 的块文件中，实现“元数据集中管理、数据分布式存储”的解耦。
- 优势：用户无需感知分布式细节（如节点数量、块位置），可通过标准 API（如 `hdfs dfs -ls`、`FileSystem.open()`）操作文件，降低使用门槛。

#### 3.2 数据块抽象（Block Abstraction）
- 核心目标：将大文件拆分为固定大小的块，简化存储管理、提升读写性能与扩展性。
- 抽象逻辑：
  1. 固定大小拆分：默认将文件按 128MB 拆分为块（可通过 `dfs.blocksize` 配置，大文件场景建议 256MB），无论文件大小，均以块为单位存储（如 1GB 文件拆分为 8 个 128MB 块）。
  2. 块独立存储：每个块作为独立单元存储在 DataNode 上，块文件名为“块 ID.blk”（如 `blk_1073741825.blk`），并生成对应的校验和文件（`.meta`）；块可独立复制、迁移、删除，简化数据管理。
  3. 块匿名化：块仅通过“块 ID”标识，与文件名解耦（同一文件的不同块有不同块 ID，不同文件的块 ID 不重复）；块 ID 由 NameNode 生成（全局唯一），确保集群内块标识唯一。
- 优势：
  - 性能优化：块大小远大于普通文件系统（如 Linux 默认 4KB），减少磁盘寻道次数（一次寻道可读取大量数据），提升 sequential read 性能。
  - 扩展性优化：单个 DataNode 可存储大量块，集群可通过新增 DataNode 线性扩展存储容量，无需修改块管理逻辑。
  - 容错优化：块可独立复制（如 3 个副本），单个块丢失仅需修复该块，无需修复整个文件。

#### 3.3 机架感知模型（Rack Awareness Model）
- 核心目标：通过感知节点的物理机架位置，优化副本分配与数据读取，平衡“容错性”与“网络性能”。
- 抽象逻辑：
  1. 机架拓扑映射：管理员通过配置 `topology.map` 或 `topology.script.file.name`，将 DataNode 的 IP 地址映射到机架路径（如 `dn1.ip → /rack1`，`dn2.ip → /rack2`），NameNode 据此维护“DataNode-机架”映射表。
  2. 副本分配策略（默认 3 副本）：
     - 第 1 个副本：存储在“客户端所在节点”（若客户端在集群外，则随机选择一个健康 DN）。
     - 第 2 个副本：存储在“与第 1 个副本不同机架”的 DN（跨机架容错，避免单机架断电导致副本丢失）。
     - 第 3 个副本：存储在“与第 2 个副本同机架、不同节点”的 DN（减少跨机架传输，提升写入性能）。
  3. 读取优化策略：NameNode 向客户端返回块副本位置时，按“机架距离”排序（优先级：客户端本地 DN > 同机架 DN > 跨机架 DN），减少跨机架网络传输（跨机架带宽通常远低于同机架）。
- 优势：
  - 容错性：副本分布在不同机架，单机架故障（如断电、交换机故障）不会导致块副本全部丢失。
  - 性能：写入时仅需 1 次跨机架传输（第 1→第 2 副本），读取时优先同机架或本地副本，降低网络带宽消耗。

#### 3.4 副本容错模型（Replica Fault Tolerance Model）
- 核心目标：通过多副本存储，确保数据在节点故障、磁盘损坏时不丢失，同时保证数据一致性。
- 抽象逻辑：
  1. 副本数量配置：通过 `dfs.replication` 配置全局默认副本数（默认 3），也可针对单个文件设置副本数（如 `hdfs dfs -setrep 5 /data/file.txt`），平衡“可靠性”与“存储成本”。
  2. 副本状态管理：NameNode 维护每个块的“副本状态”（有效/无效）：
     - 有效副本：已完成写入（非临时块 `.blk.tmp`）、校验和正常、所在 DN 健康。
     - 无效副本：未完成写入（临时块）、校验和错误（数据损坏）、所在 DN 死亡。
  3. 副本修复机制：NameNode 定期检查块的有效副本数，若低于配置值（如副本数 3 变为 2），立即触发“副本复制”（从有效副本复制到健康 DN），直至有效副本数恢复到配置值。
  4. 数据一致性保障：
     - 写入一致性：通过“管道传输”确保所有副本同时接收相同数据（某副本接收失败则中断传输，重新建立管道），避免副本数据不一致。
     - 读取一致性：客户端读取块时，DN 先验证校验和（与 `.meta` 文件对比），校验失败则拒绝读取，客户端自动切换到其他有效副本，确保读取的数据正确。
- 优势：多副本存储是 HDFS 数据可靠性的核心保障，即使部分节点/磁盘故障，仍能通过有效副本提供服务，无数据丢失；同时通过校验和与状态管理，确保数据一致性。


### 4. 数据/信息流转：数据怎么流动
HDFS 中的数据流转包括“写文件数据流”“读文件数据流”“元数据流”“块修复数据流”四类核心场景，流转逻辑围绕“元数据集中管理、数据分布式传输”展开，HA 模式与非 HA 模式的差异集中在元数据流。

#### 4.1 写文件时的数据流转（用户数据从客户端到 DataNode）
写文件数据流转的核心是“管道传输”，确保数据同时写入多个副本，且传输效率高，以 HA 模式为例（非 HA 模式仅元数据节点不同）：

1. 客户端 → Active NameNode（元数据请求流）：
   - 客户端发送“创建文件请求”→ Active NN 校验权限与路径 → 返回“可写标识”。
   - 客户端缓存满一块数据 → 发送“块申请请求”→ Active NN 分配块 ID 与 3 个副本位置 → 返回“块 ID + 副本 DN 列表”。

2. 客户端 → DataNode 集群（数据传输流，管道模式）：
   - 客户端与第 1 个副本 DN（如 DN1）建立 TCP 连接 → DN1 与第 2 个副本 DN（DN2）建立连接 → DN2 与第 3 个副本 DN（DN3）建立连接 → 形成 `Client→DN1→DN2→DN3` 管道。
   - 客户端将数据切分为 64KB 数据包 → 按顺序写入管道 → DN1 接收数据包后，先写入本地临时文件（`.blk.tmp`），再转发给 DN2 → DN2 同理转发给 DN3。

3. DataNode 集群 → 客户端（ACK 确认流）：
   - DN3 接收数据包并写入临时文件后，向 DN2 发送 ACK → DN2 接收 ACK 后，向 DN1 发送 ACK → DN1 接收 ACK 后，向客户端发送 ACK。
   - 客户端接收所有 DN 的 ACK，确认当前数据包传输成功，继续发送下一个数据包。

4. DataNode 集群 → Active NameNode（块完成流）：
   - 当前块所有数据包传输完成 → 客户端发送“块结束信号”→ DN1、DN2、DN3 将临时文件重命名为正式块文件（`.blk`），生成校验和文件（`.meta`）。
   - DN1、DN2、DN3 向 Active NN 发送“块完成请求”→ Active NN 更新元数据（文件-块映射、块-副本位置）→ 将元数据变更写入 JournalNodes 集群（edits 日志）。

5. Active NameNode → Standby NameNode（元数据同步流，HA 模式特有）：
   - Standby NN 从 JournalNodes 读取新 edits 日志 → 重放日志更新本地内存镜像 → 与 Active NN 元数据保持一致。

#### 4.2 读文件时的数据流转（用户数据从 DataNode 到客户端）
读文件数据流转的核心是“就近读取”，优先选择距离客户端最近的副本，减少网络传输，以 HA 模式为例：

1. 客户端 → Active/Standby NameNode（元数据请求流）：
   - 客户端发送“打开文件请求”→ Active/Standby NN 校验权限 → 返回“文件的块列表 + 每个块的副本 DN 列表”（按机架距离排序）。

2. 客户端 → 目标 DataNode（数据读取流）：
   - 客户端选择最近的副本 DN（如本地 DN 或同机架 DN）→ 建立 TCP 连接 → 发送“块读取请求”（含块 ID 与读取偏移量）。
   - DN 读取本地块文件（`.blk`）与校验和文件（`.meta`）→ 计算当前数据的校验和 → 与 `.meta` 对比，确认数据完整 → 将数据按请求偏移量返回给客户端。

3. 客户端本地（数据拼接流）：
   - 客户端接收当前块数据 → 存入本地缓存（可选）→ 继续读取下一个块（重复步骤 2）。
   - 所有块读取完成 → 客户端在本地内存中拼接所有块数据 → 形成完整文件，返回给用户应用。

#### 4.3 HA 模式下元数据的流转（元数据从 Active NN 到 Standby NN）
元数据流转是 HA 模式“双 NN 状态一致”的核心，确保 Active NN 故障时，Standby NN 可无缝接管，流转逻辑如下：

1. Active NN 生成元数据变更（来源）：
   - 来源 1：客户端请求（如创建文件、删除目录、修改副本数）。
   - 来源 2：集群内部事件（如 DataNode 宕机导致块副本减少、块修复完成导致副本增加）。
   - Active NN 处理上述事件，生成对应的元数据变更操作（如添加文件元数据、删除块映射）。

2. Active NN → JournalNodes 集群（元数据日志流）：
   - Active NN 将元数据变更封装为 `edits` 日志条目（含事务 ID、操作类型、操作内容）。
   - Active NN 通过 RPC 将 `edits` 日志发送到所有 JN → 每个 JN 接收后写入本地磁盘 → 向 Active NN 返回“写入成功”确认。
   - Active NN 收到超过半数 JN 的确认后，更新本地内存镜像（应用该元数据变更）。

3. JournalNodes 集群 → Standby NN（元数据同步流）：
   - Standby NN 启动“日志拉取线程”，每 100ms 从 JNs 读取新 `edits` 日志（按事务 ID 顺序，避免跳号）。
   - Standby NN 将读取的 `edits` 日志在本地内存中“重放”（执行相同的元数据变更操作）→ 更新自身内存镜像，确保与 Active NN 状态一致。

4. Standby NN → Active NN（元数据快照同步流）：
   - Standby NN 满足 Checkpoint 条件时，合并本地 `fsimage` 与未合并的 `edits` 日志 → 生成新 `fsimage`。
   - Standby NN 将新 `fsimage` 同步到 Active NN → Active NN 替换旧 `fsimage` → 双 NN `fsimage` 版本统一。

#### 4.4 块修复时的数据流转（数据从有效副本 DN 到目标 DN）
块修复是 HDFS 容错的核心，当块副本数低于配置值时，通过复制有效副本来恢复副本数，流转逻辑如下：

1. NameNode 触发块修复（触发源）：
   - 触发场景 1：DataNode 宕机（NN 标记该 DN 上的块为“无效”，副本数减少）。
   - 触发场景 2：DataNode 汇报块损坏（DN 校验块时发现校验和不匹配，向 NN 汇报“块损坏”）。
   - NN 扫描块副本数 → 发现某块副本数 < 配置值 → 选择“有效副本 DN”（存储该块有效副本的 DN）与“目标 DN”（待写入新副本的健康 DN）。

2. 有效副本 DN → 目标 DN（块数据传输流）：
   - NN 向有效副本 DN 发送“块复制指令”（含目标 DN 地址、块 ID）。
   - 有效副本 DN 与目标 DN 建立 TCP 连接 → 有效副本 DN 读取本地块文件（`.blk`）与校验和文件（`.meta`）→ 将块数据与校验和按 64KB 数据包发送到目标 DN。
   - 目标 DN 接收数据包 → 先写入临时文件（`.blk.tmp`）→ 接收完成后，验证校验和（与有效副本 DN 发送的校验和对比）→ 校验通过则将临时文件重命名为正式块文件（`.blk`），生成 `.meta` 文件。

3. 目标 DN → NameNode（块修复确认流）：
   - 目标 DN 向 NN 发送“块复制完成请求”→ NN 更新该块的“副本位置映射”（添加目标 DN 为新副本）。
   - NN 检查该块的副本数 → 若恢复到配置值，标记“块修复完成”；若仍不足，继续选择其他目标 DN 重复步骤 2。

## 三、 实践应用 (How - Practice)

### 1.1 基本操作 / 技能点：最小可用集

#### 1.1.1 文件系统基础操作

*   **查看帮助**: `hdfs dfs -help <command>` (如 `hdfs dfs -help put`)
*   **列出目录**: `hdfs dfs -ls [-h] [-R] <path>`
    *   `-h`: 人性化显示文件大小 (e.g., 64M, 2.1G)
    *   `-R`: 递归列出子目录
*   **创建目录**: `hdfs dfs -mkdir [-p] <path>`
    *   `-p`: 递归创建父目录
*   **上传文件/目录**:
    *   `hdfs dfs -put <localsrc> ... <dst>` (从本地拷贝)
    *   `hdfs dfs -copyFromLocal <localsrc> ... <dst>` (同 `-put`)
    *   `hdfs dfs -moveFromLocal <localsrc> ... <dst>` (移动本地文件)
*   **下载文件/目录**:
    *   `hdfs dfs -get <src> <localdst>` (拷贝到本地)
    *   `hdfs dfs -copyToLocal <src> <localdst>` (同 `-get`)
    *   `hdfs dfs -getmerge <src> <localdst>` (合并小文件后下载)
*   **查看文件内容**:
    *   `hdfs dfs -cat <path>` (输出全部内容)
    *   `hdfs dfs -tail [-f] <path>` (查看尾部，`-f` 类似 `tail -f`)
*   **拷贝/移动文件**:
    *   `hdfs dfs -cp <src> <dst>` (HDFS内部拷贝)
    *   `hdfs dfs -mv <src> <dst>` (HDFS内部移动)
*   **删除文件/目录**:
    *   `hdfs dfs -rm <path>` (删除文件)
    *   `hdfs dfs -rm -r <path>` (递归删除目录)
    *   `hdfs dfs -rm -r -skipTrash <path>` (直接跳过回收站删除，**生产环境慎用**)
*   **查看磁盘使用情况**: `hdfs dfs -du [-h] [-s] <path>`
    *   `-s`: 显示目录总大小
    * `-h`: 人性化显示

#### 1.1.2 文件权限与所有权
*   **更改属主/组**: `hdfs dfs -chown [-R] <owner>[:group] <path>`
*   **更改权限**: `hdfs dfs -chmod [-R] <mode> <path>`
*   HDFS 权限模型与 Linux 类似 (rwx)，但默认配置下可能未开启强权限校验。

#### 1.1.3 管理命令 (高级用户/运维)
*   **平衡数据**: `hdfs balancer [-threshold <threshold>]` (使DataNode磁盘使用率均衡)
*   **进入安全模式**: `hdfs dfsadmin -safemode enter|leave|get|wait`
*   **查看报告**: `hdfs dfsadmin -report` (查看集群状态)

### 1.2 典型案例：实践中的代表性例子

#### 1.2.1 日志存储与分析 (最经典场景)
*   **场景**: 各类服务器 (Web, App) 产生大量日志文件，需要集中存储并进行离线分析 (如使用 MapReduce, Hive, Spark)。日均数据量 100GB-1TB，需保留 30 天用于问题排查与分析
*   **操作流程**:
    1.  应用服务器使用 `Flume`, `Sqoop` 或定时脚本通过 `hdfs dfs -put` 将日志写入 HDFS。
    2.  写入路径通常按日期分区，例如：`/logs/app1/2023-10-27/`。这有利于后续处理。
    3.  数据分析师通过 Hive 创建外部表，指定 LOCATION 指向该目录，即可直接查询。
    4.  定期清理：通过`hdfs dfs -rm -r /logs/*/$(date -d "-30 days" +%Y%m%d)`清理 30 天前日志。
    5.  监控：重点监控 DataNode 磁盘使用率（阈值≤85%）、块丢失数（阈值 = 0）

#### 1.2.2 海量数据备份与归档
*   **场景**: 将数据库冷数据、历史文件等转移到 HDFS，利用其廉价存储的优势。处理日均 1TB-10TB 业务数据（订单、用户、交易数据），支撑报表分析、数据挖掘

*   **操作流程**:
    1.  使用 `Sqoop、datax` 等工具将数据库中的表批量导入 HDFS。
    2.  对于不再频繁访问但需要保留的数据，可以启用 **HDFS Erasure Coding (EC)** 或转移到更廉价的存储层级 (Archival Storage)，节省一半以上的存储空间。

- **场景优化：**
    1.  机架感知：启用`dfs.network.topology.script.file.name`，避免同一机架 DataNode 故障导致副本丢失
    2.  客户端缓存：`dfs.client.read.prefetch.size=134217728（128MB）`，提升 Hive 读取速度
    3.  数据安全与权限控制
      - HDFS ACL：为 Hive 用户配置目录权限（如`hdfs dfs -setfacl -m user:hive:rwx /user/hive/warehouse`）
      - Ranger 集成：通过 Ranger 实现表级、列级权限控制，防止敏感数据泄露
      - 数据加密：启用 HDFS 传输加密（TLS/SSL）与存储加密（AES），保护敏感数据

#### 1.2.3 作为数据仓库的底层存储 (Hive Warehouse)
*   **场景**: Hive 表的底层数据实际存储在 HDFS 上。了解 HDFS 有助于优化 Hive 性能。基于 Spark 执行离线批处理任务（如用户画像计算），基于 Flink 执行实时流处理任务（如实时交易额统计），HDFS 作为计算任务的输入源与结果存储层
*   **关联知识**:
    *   Hive 表的文件数量和大小直接影响 MapReduce 或 Spark 的任务数。
    *   应避免过多小文件，可以通过 `INSERT OVERWRITE ...` 合并或使用 `hdfs dfs -getmerge`。
    - 客户端并行度：Spark 任务设置`--conf spark.hadoop.dfs.client.read.threads=10`，提升并行读取能力
    - IO 缓存：Flink 任务设置`--conf fs.hdfs.block.size=268435456（256MB）`，减少 IO 请求次数
    - 写缓冲：`dfs.datanode.block.write.cache.size=134217728（128MB）`，减少 DataNode 刷盘频率
    - 任务读写 HDFS 超时：检查网络连通性（ping、telnet），调大`dfs.client.socket-timeout=600000（10 分钟）`
    - 块丢失导致任务失败：执行`hdfs dfsadmin -repor`t查看块状态，恢复下线 DataNode 或强制复制副本（`hdfs dfsadmin -setReplication /path 3`）

### 1.3 常见问题与解决：遇到坑时如何处理

#### 1. NameNode 单点故障（非 HA 场景）
##### 1.1 问题现象
- 集群 **不可写**：无法创建目录、上传文件，元数据更新失败。
- 进程与 UI 异常：NameNode（NN）进程消失，Web UI（http://nn1:9870）无法访问或报错。
- 日志提示：NN 日志中出现进程崩溃、内存溢出（OOM）等关键错误。

##### 1.2 根本原因
非 HA 架构下仅部署 1 个 NameNode，核心故障场景包括：
- 节点级故障：硬件损坏（如主板、内存故障）、操作系统崩溃。
- 进程级故障：NN 堆内存不足导致 OOM、配置文件错误（如 `hdfs-site.xml` 参数写错）、元数据文件损坏。

##### 1.3 排查步骤
1. 查看 NN 日志：定位故障根因，日志路径为 `$HADOOP_HOME/logs/hadoop-*-namenode-*.log`（`*` 为用户名和节点名）。
   - 若日志含 `OutOfMemoryError`：确认 JVM 内存参数不足。
   - 若日志含 `Invalid configuration`：检查 `core-site.xml`、`hdfs-site.xml` 配置。
2. 检查 NN 节点状态：执行 `ssh nn1` 确认节点是否可登录，若无法登录则为硬件/OS 故障。

##### 1.4 解决办法
- 临时恢复（节点可修复）
  - 若节点可登录且仅进程崩溃：直接重启 NN，命令为 `hdfs --daemon start namenode`。
  - 若节点可登录但元数据异常（依赖 SecondaryNameNode）：
    1. 复制 SecondaryNameNode（SNN）的元数据文件到 NN 目录：  
       `scp snn1:/data/hadoop/secondarynamenode/* nn1:/data/hadoop/namenode/`（路径需与 `hdfs-site.xml` 中 `dfs.namenode.name.dir` 一致）。
    2. 重启 NN：`hdfs --daemon start namenode`。

- 根治方案（部署 HA 架构）
通过“2 个 NN（主备）+ 3 个 JournalNode（JN）+ ZKFC”实现主备自动切换，核心配置（`hdfs-site.xml`）如下：
```xml
<!-- 1. 定义集群名称 -->
<property>
  <name>dfs.nameservices</name>
  <value>hdfscluster</value>
</property>
<!-- 2. 定义主备 NN 节点 -->
<property>
  <name>dfs.ha.namenodes.hdfscluster</name>
  <value>nn1,nn2</value>
</property>
<!-- 3. 主 NN RPC 地址（客户端通信） -->
<property>
  <name>dfs.namenode.rpc-address.hdfscluster.nn1</name>
  <value>nn1:9000</value>
</property>
<!-- 4. 备 NN RPC 地址 -->
<property>
  <name>dfs.namenode.rpc-address.hdfscluster.nn2</name>
  <value>nn2:9000</value>
</property>
<!-- 5. 元数据共享存储（JournalNode 集群） -->
<property>
  <name>dfs.namenode.shared.edits.dir</name>
  <value>qjournal://jn1:8485;jn2:8485;jn3:8485/hdfscluster</value>
</property>
<!-- 6. 客户端故障转移代理 -->
<property>
  <name>dfs.client.failover.proxy.provider.hdfscluster</name>
  <value>org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider</value>
</property>
<!-- 7. 隔离机制（防止脑裂） -->
<property>
  <name>dfs.ha.fencing.methods</name>
  <value>sshfence</value> <!-- 通过 SSH 杀死旧主 NN 进程 -->
</property>
<!-- 8. 隔离机制依赖的 SSH 私钥 -->
<property>
  <name>dfs.ha.fencing.ssh.private-key-files</name>
  <value>/root/.ssh/id_rsa</value>
</property>
```

##### 1.5 生产预防措施
- 定期备份元数据：执行 `hdfs dfsadmin -fetchImage /backup`，将备份文件跨节点存储（如存到独立备份节点）。
- 监控告警：通过 Prometheus+Grafana 监控 NN 堆内存使用率（阈值 ≤85%）、进程状态，触发告警后及时处理。
- 预分配内存：根据文件数量调整 NN JVM 内存（每百万文件约需 1GB 内存，如千万文件设 `-Xmx10g`）。


#### 2. DataNode 心跳超时/下线
##### 2.1 问题现象
- Web UI 异常：NN Web UI 的 `DataNodes` 页面中，目标 DataNode（DN）状态为 `Decommissioned`（退役）或 `Dead`（死亡）。
- 集群状态异常：执行 `hdfs dfsadmin -report` 显示 DN 数量减少，且 `Under-Replicated Blocks`（副本不足块）增多。
- 任务失败：计算任务（如 Spark）读取数据时因找不到 DN 报错。

##### 2.2 根本原因
1. 网络故障：NN 与 DN 之间网络中断（防火墙拦截 9866 端口、交换机故障、网线松动）。
2. 资源不足：
   - 磁盘满：DN 数据目录（`dfs.datanode.data.dir`）对应磁盘使用率 100%。
   - 内存溢出：DN JVM 内存参数过小，导致进程 OOM 崩溃。
3. 进程异常：DN 进程因配置错误（如 `hadoop-env.sh` 环境变量写错）或硬件故障（如磁盘损坏）退出。

##### 2.3 排查步骤
1. 检查网络连通性：
   - 在 NN 节点 ping DN 节点：`ping dn1`（确认节点可达）。
   - 测试 DN 核心端口：`telnet dn1 9866`（确认 IPC 端口未被拦截）。
2. 检查 DN 磁盘状态：在 DN 节点执行 `df -h`，查看 `dfs.datanode.data.dir` 对应磁盘的使用率。
3. 查看 DN 日志：日志路径为 `$HADOOP_HOME/logs/hadoop-*-datanode-*.log`，搜索 `ERROR` 或 `OutOfMemoryError` 定位故障。

##### 2.4 解决办法
1. 网络故障修复：
   - 关闭 DN 节点防火墙：`systemctl stop firewalld` 并设置开机禁用 `systemctl disable firewalld`。
   - 修复交换机/网线故障，确保 NN 与 DN 网络互通。
   - 重启 DN：`hdfs --daemon start datanode`。
2. 磁盘满修复：
   - 删除 DN 节点无用数据（如过期日志、临时文件），确保磁盘使用率 ≤85%。
   - 扩展磁盘：新增磁盘并挂载到 `dfs.datanode.data.dir` 配置的路径下。
   - 刷新 DN 状态：`hdfs dfsadmin -refreshNodes`。
3. 内存溢出修复：
   - 调整 DN JVM 内存：修改 `$HADOOP_HOME/etc/hadoop/hadoop-env.sh`，设置 `export HADOOP_DATANODE_OPTS="-Xmx4g $HADOOP_DATANODE_OPTS"`（根据集群规模调整，一般设 4-8GB）。
   - 重启 DN：`hdfs --daemon stop datanode && hdfs --daemon start datanode`。

##### 2.5 生产优化
- 调大心跳超时参数：在 `hdfs-site.xml` 中配置：
  - `dfs.namenode.heartbeat.recheck-interval`：心跳重检间隔，设为 300000（5 分钟，默认 30 秒，避免网络抖动误判）。
  - `dfs.datanode.heartbeat.interval`：DN 主动心跳间隔，设为 3（3 秒，默认 3 秒，无需修改）。
- 磁盘监控告警：通过 Zabbix/Prometheus 监控 DN 磁盘使用率，阈值设为 85%（达阈值触发邮件/短信告警）。
- 多磁盘部署：将 `dfs.datanode.data.dir` 配置为多个独立磁盘目录（如 `/data1/dn,/data2/dn`），分散 IO 压力。


#### 3. HDFS 块丢失（Corrupt Blocks / Missing Blocks）
##### 3.1 问题现象
- 集群状态异常：执行 `hdfs dfsadmin -report` 显示 `Missing Blocks`（丢失块）数量 > 0。
- 任务失败：计算任务（如 Spark、MapReduce）读取数据时报错 `BlockMissingException: Could not obtain block`。
- 文件损坏：执行 `hdfs dfs -cat /path/file` 时报错“块不存在”。

##### 3.2 根本原因
1. DN 永久下线：DN 节点硬件损坏（如主板故障）无法恢复，导致该节点上的块无其他副本。
2. 磁盘损坏：DN 某块磁盘物理损坏，该磁盘上的块无法访问。
3. 副本数不足：`dfs.replication`（默认 3）配置过小（如设为 1），单节点/磁盘故障即导致块丢失。
4. 元数据与数据不一致：NN 元数据记录块存在，但 DN 实际数据文件损坏或丢失。

##### 3.3 排查步骤
1. 定位丢失块详情：执行 `hdfs fsck / -blocks -locations`，该命令会列出所有丢失块的文件路径、预期副本数、实际存储位置。
   - 示例输出：`/user/test.txt: MISSING 1 blocks of total size 128 MB`。
2. 确认 DN 状态：通过 `hdfs dfsadmin -report` 检查丢失块对应的 DN 是否处于 `Dead` 状态。
3. 检查 DN 磁盘：在目标 DN 节点执行 `ls -l /data/dn/current`，确认块数据文件（如 `blk_1073741824`）是否存在。

##### 3.4 解决办法
1. 恢复可修复的 DN：
   - 若 DN 仅进程崩溃（节点可登录）：重启 DN 后，NN 会自动从其他健康 DN 同步缺失块。
   - 若 DN 硬件故障修复：修复后重启 DN，执行 `hdfs datanode -rollback` 恢复数据，再等待块同步。
2. 替换损坏磁盘：
   - 在 DN 节点移除损坏磁盘，挂载新磁盘并格式化。
   - 修改 `dfs.datanode.data.dir` 配置（若路径变化），重启 DN 后执行 `hdfs dfsadmin -refreshNodes`。
3. 强制补充副本：
   - 若 DN 无法恢复，对丢失块的文件强制设置副本数：`hdfs dfsadmin -setReplication /path/file 3`（将副本数设为 3）。
   - NN 会自动调度健康 DN 复制块，修复后 `Missing Blocks` 数量会归零。
4. 删除无用文件：若丢失块的文件不重要，直接删除以清理元数据：`hdfs dfs -rm /path/file`。

##### 3.5 生产预防措施
- 监控告警：设置 `Missing Blocks > 0` 立即告警（通过 Prometheus+Grafana），避免故障扩散。
- 定期检查：通过 Crontab 每日凌晨执行 `hdfs fsck / > /var/log/hdfs/fsck_$(date +%Y%m%d).log`，日志留存 7 天便于回溯。
- 合理配置副本数：生产环境 `dfs.replication` 建议设为 3（适用于 3 个及以上 DN 的集群），避免单节点故障风险。
- 启用 EC 编码：对大容量冷数据启用 Erasure Coding（EC，纠删码），如 `RS-6-3-1024k`（6 个数据块+3 个校验块，存储开销比副本低 50%）。


#### 4. 小文件泛滥（NameNode 内存压力大）
##### 4.1 问题现象
- NN 内存使用率高：NN 堆内存使用率持续 > 90%，元数据操作（如 `hdfs dfs -ls`、创建目录）响应缓慢。
- 文件数量异常：执行 `hdfs dfs -count /` 显示文件数量达数百万甚至数千万（每百万文件约占用 NN 1GB 内存）。
- 计算效率低：MapReduce/Spark 读取小文件时生成过多任务（每个小文件对应 1 个 Map 任务），任务调度开销远超计算开销。

##### 4.2 根本原因
1. 数据源头未控制：日志采集（如 Flume）、应用写入（如实时计算输出）未合并小文件，直接写入 HDFS。
2. 业务场景特性：如用户行为日志、传感器数据等，天然生成大量小文件（单文件 < 100MB）。
3. 缺乏治理机制：未定期清理或合并历史小文件，导致累积泛滥。

##### 4.3 解决办法
- **源头预防（推荐优先）**
1. 实时采集合并（Flume）：
   - 在 Flume 配置文件中设置滚动策略，控制输出文件大小：
     ```properties
     # 当文件达到 128MB 时滚动（单位：字节）
     hdfs.rollSize = 134217728
     # 当文件写入超过 30 分钟时滚动（单位：秒）
     hdfs.rollInterval = 1800
     # 当文件行数达到 100 万时滚动
     hdfs.rollCount = 1000000
     ```
2. 计算输出合并（Spark/Flink）：
   - Spark 输出时用 `coalesce` 或 `repartition` 减少分区数（避免每个分区对应 1 个小文件）：
     ```scala
     // 读取小文件后合并为 10 个分区（输出 10 个大文件）
     val df = spark.read.text("/input/small_files/")
     df.coalesce(10).write.mode("overwrite").text("/output/large_files/")
     ```

- **存量治理（历史小文件）**
1. 离线合并（Spark 脚本）：
   ```scala
   import org.apache.spark.sql.SparkSession
   
   object MergeSmallFiles {
     def main(args: Array[String]): Unit = {
       val spark = SparkSession.builder()
         .appName("MergeSmallFiles")
         .master("yarn") // 生产环境用 yarn 模式
         .getOrCreate()
   
       // 读取小文件（支持多种格式：text、parquet、csv 等）
       val smallFilesDF = spark.read.text("/input/historical_small_files/")
   
       // 合并为 128MB 左右的大文件（根据总数据量估算分区数）
       val totalSizeMB = 10240 // 总数据量 10GB
       val partitionNum = (totalSizeMB / 128).toInt // 分 80 个分区
       smallFilesDF.repartition(partitionNum)
         .write.mode("overwrite")
         .text("/output/merged_large_files/")
   
       spark.stop()
     }
   }
   ```
2. Hadoop Archive（HAR）归档：
   - 创建 HAR 文件（将小文件打包为归档文件，元数据仅记录 HAR 索引，减少 NN 内存占用）：
     ```bash
     # -archiveName：HAR 文件名；-p：源路径；最后为目标路径
     hadoop archive -archiveName files.har -p /input/small_files /output/har
     ```
   - 访问 HAR 文件：`hdfs dfs -cat har:///output/har/files.har/small_file.txt`。
3. 替换存储方案：
   - 小文件量极大（如数十亿）时，改用 HBase 存储（HBase 将小文件合并为 HFile，仅需 NN 记录 HFile 元数据，大幅减少 NN 压力）。
   - 用 SequenceFile 打包：将多个小文件写入 1 个 SequenceFile（Key 为文件名，Value 为文件内容），示例代码可参考 Hadoop 官方 API。

##### 4.4 生产落地
- 定时任务：通过 Linux Crontab 每日凌晨执行小文件合并脚本（如 Spark 脚本），命令示例：
  ```bash
  # 每天 2 点执行合并脚本
  0 2 * * * spark-submit --class MergeSmallFiles --master yarn /opt/scripts/merge-small-files.jar
  ```
- 写入限制：在客户端（如 Flume、应用程序）设置过滤规则，禁止单个文件 < 1MB 直接写入 HDFS（小文件先缓存到本地，达到阈值后再合并上传）。
- 监控文件数：通过 Prometheus 监控 HDFS 总文件数，当文件数接近 NN 内存承载上限（如千万级）时触发告警。


#### 5. HDFS 读写性能低下
##### 5.1 问题现象
- 客户端读写慢：上传/下载文件速度 < 100MB/s（正常万兆网络+SSD 环境应达 300-500MB/s）。
- 计算任务 IO 等待高：Spark UI 中 `Shuffle Read Time`/`Shuffle Write Time` 占比 > 50%，任务总耗时主要消耗在 IO 上。
- 集群指标异常：DN Web UI（http://dn1:9864）显示 `Bytes Written/Read` 吞吐量远低于硬件上限。

##### 5.2 瓶颈定位
- 系统资源瓶颈（先排查）
1. 磁盘 IO 瓶颈：在 DN 节点执行 `iostat -x 1`，查看 `%util`（磁盘使用率），若持续 > 90% 则为磁盘瓶颈。
2. 网络瓶颈：在 NN/DN 节点执行 `iftop`，查看网络带宽使用率，若持续 > 90% 则为网络瓶颈。
3. CPU/内存瓶颈：执行 `top`，若 `%Cpu(s)` > 80% 或 `%Mem` > 90%，需排查是否有其他进程占用资源。

- HDFS 内部瓶颈（再排查）
1. NN 瓶颈：
   - 查看 NN Web UI 的 `Metrics` 页面，若 `RPC QPS` 接近上限（默认约 10000 QPS）或 `Block Operations` 延迟 > 100ms，则 NN 为瓶颈。
   - 检查 NN 堆内存使用率，若 > 90% 则内存不足。
2. DN 瓶颈：
   - 查看 DN Web UI 的 `Metrics` 页面，若 `DataNode Block IO` 中 `Write/Read Throughput` 远低于磁盘标称速度（如 HDD 约 100MB/s，SSD 约 500MB/s），则 DN 为瓶颈。

##### 5.3 针对性解决办法
- 磁盘瓶颈解决
1. 多磁盘分散 IO：将 `dfs.datanode.data.dir` 配置为多个独立磁盘目录（如 `/data1/dn,/data2/dn,/data3/dn`），避免单磁盘 IO 过载。
2. 升级存储介质：核心 DN 节点（如存储热数据）用 SSD 替代 HDD，SSD 随机读写性能是 HDD 的 10-100 倍。
3. 调整 IO 调度算法：
   - HDD 推荐 `mq-deadline`（适合批量 IO）：`echo mq-deadline > /sys/block/sda/queue/scheduler`。
   - SSD 推荐 `noop`（减少 CPU 开销）：`echo noop > /sys/block/sda/queue/scheduler`。

- 网络瓶颈解决
1. 升级网络硬件：将 NN/DN 节点网卡从千兆（1G）升级为万兆（10G），核心交换机升级为万兆交换机。
2. 启用机架感知：在 `core-site.xml` 中配置 `net.topology.node.switch.mapping.impl`，让 NN 优先将副本分配到不同机架，计算任务优先读取本地机架数据，减少跨机架 IO。
3. 调大 TCP 缓冲区：修改 Linux 内核参数（`/etc/sysctl.conf`），提升网络吞吐量：
   ```bash
   # 最大 TCP 连接数
   net.core.somaxconn = 1024
   # TCP 写缓冲区（最小/默认/最大，单位：字节）
   net.ipv4.tcp_wmem = 4096 65536 16777216
   # TCP 读缓冲区（最小/默认/最大，单位：字节）
   net.ipv4.tcp_rmem = 4096 65536 16777216
   ```
   执行 `sysctl -p` 使配置生效。

- NN 瓶颈解决
1. 扩容 NN 内存：修改 `hadoop-env.sh`，设置 `export HADOOP_NAMENODE_OPTS="-Xmx16g $HADOOP_NAMENODE_OPTS"`（根据文件数量调整，每百万文件约 1GB）。
2. 部署联邦（Federation）：将 HDFS 命名空间拆分（如 `/user` 由 nn1 管理，`/logs` 由 nn2 管理），每个 NN 独立负责部分元数据，分散压力。

- 客户端优化
1. 多线程读写：客户端用多线程并行上传/下载，如 Java API 中用 `ExecutorService` 创建线程池，示例：
   ```java
   ExecutorService executor = Executors.newFixedThreadPool(10); // 10 线程
   for (String filePath : filePaths) {
     executor.submit(() -> hdfsClient.copyFromLocalFile(new Path(filePath), new Path("/hdfs/path/")));
   }
   executor.shutdown();
   ```
2. 启用预读取：在 `hdfs-site.xml` 中配置 `dfs.client.read.prefetch.size = 268435456`（256MB），让客户端提前读取后续块数据，减少 IO 等待。

##### 5.4 生产优化
- 性能基准测试：定期用 `hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-client-jobclient-*.jar TestDFSIO -write -nrFiles 10 -fileSize 128MB` 测试 HDFS 读写性能，建立基准值。
- 热数据分区：将热数据（如最近 7 天的日志）存储在 SSD 节点，冷数据存储在 HDD 节点，平衡性能与成本。
- 监控吞吐量：通过 Prometheus 监控 DN 的 `datanode_bytes_written` 和 `datanode_bytes_read` 指标，当吞吐量下降 30% 时触发告警。


#### 6. 磁盘空间不足
##### 6.1 问题现象
- 上传失败：执行 `hdfs dfs -put localfile /hdfs/path` 时报错 `Could only be replicated to 0 nodes instead of minReplication (=1)`。
- 集群状态异常：`hdfs dfsadmin -report` 显示多个 DN 剩余空间 < 10%。
- 任务失败：计算任务写入中间结果时因磁盘满报错。

##### 6.2 根本原因
1. 数据量增长：业务数据持续写入，未定期清理过期数据（如超过 30 天的日志）。
2. 垃圾回收站过大：HDFS 垃圾回收站（默认保留 7 天）堆积大量删除文件，未及时清空。
3. 副本数过高：`dfs.replication` 设为 3 以上，导致存储开销过大（如 100GB 数据存 4 副本占用 400GB）。

##### 6.3 排查步骤
1. 查看集群总用量：执行 `hdfs dfs -du -s -h /`，确认 HDFS 总占用空间。
2. 查看 DN 剩余空间：执行 `hdfs dfsadmin -report`，定位剩余空间不足的 DN 节点。
3. 检查垃圾回收站：执行 `hdfs dfs -du -s -h /user/$(whoami)/.Trash`，确认是否有大量垃圾文件。

##### 6.4 解决办法
1. 清理过期数据：
   - 删除业务无关数据：如 `hdfs dfs -rm -r /logs/202401*`（删除 2024 年 1 月的日志）。
   - 清空垃圾回收站：执行 `hdfs dfs -expunge`（立即清理，无需等待 7 天默认周期）。
2. 扩展存储：
   - 新增 DN 节点：部署新 DN 节点并加入集群，执行 `hdfs dfsadmin -refreshNodes` 刷新状态。
   - 扩容 DN 磁盘：在现有 DN 节点新增磁盘，挂载到 `dfs.datanode.data.dir` 路径下。
3. 优化存储策略：
   - 启用 EC 编码：对冷数据（如超过 30 天的数据）启用 EC（如 `RS-6-3`），存储开销比 3 副本低 50%。
   - 降低非核心数据副本数：执行 `hdfs dfsadmin -setReplication /non-core-data 2`（将非核心数据副本数设为 2）。

##### 6.5 生产预防措施
- 数据生命周期管理：用 Apache Ranger 或自定义脚本，定期（如每月）删除过期数据（需业务确认可删除）。
- 监控磁盘使用率：设置 DN 磁盘使用率阈值（如 85%），达阈值时触发告警，提前清理或扩容。
- 合理配置副本：核心数据（如业务表）设为 3 副本，非核心数据（如日志）设为 2 副本，冷数据用 EC。


#### 7. 权限被拒绝（Permission Denied）
##### 7.1 问题现象
- 操作失败：执行 `hdfs dfs -ls /user/admin` 或 `hdfs dfs -put` 时报错 `org.apache.hadoop.security.AccessControlException: Permission denied`。
- Kerberos 认证失败：若启用 Kerberos，客户端未认证时报错 `javax.security.sasl.SaslException: GSS initiate failed`。

##### 7.2 根本原因
1. 文件权限不足：当前用户对目标路径无 `r`（读）、`w`（写）、`x`（执行，目录需）权限。
2. 所有者不匹配：目标路径所有者为 `admin`，当前用户为 `test`，且未配置组权限或其他用户权限。
3. Kerberos 未认证：启用 Kerberos 后，用户未执行 `kinit` 或凭证过期。

##### 7.3 排查步骤
1. 检查路径权限：执行 `hdfs dfs -ls /user/`，查看目标路径的权限（如 `drwxr-xr-x   - admin supergroup          0 2024-05-01 10:00 /user/admin`）。
2. 确认当前用户：执行 `whoami`，确认当前操作系统用户与 HDFS 用户名一致（HDFS 默认使用操作系统用户名）。
3. 检查 Kerberos 状态：执行 `klist`，若显示 `klist: No credentials cache found`，则未认证。

##### 7.4 解决办法
1. 调整文件权限：
   - 管理员授予权限：`hdfs dfs -chmod 755 /user/admin`（给其他用户读和执行权限）。
   - 变更所有者：`hdfs dfs -chown test:test /user/admin`（将所有者改为当前用户 `test`）。
2. Kerberos 认证：
   - 执行 `kinit test`，输入用户 `test` 的 Kerberos 密码（若为密钥文件，执行 `kinit -kt /etc/krb5.keytab test`）。
   - 验证认证：`klist` 显示凭证有效期（如 `Valid starting     Expires            Service principal`）。

##### 7.5 生产优化
- 权限规划：提前规划 HDFS 目录权限（如 `/user` 下每个用户对应独立目录，权限设为 `700`），避免权限混乱。
- Kerberos 自动认证：在客户端机器配置 Crontab，每 23 小时执行一次 `kinit -kt /etc/krb5.keytab test`（避免凭证 24 小时过期）。
- 权限审计：用 Apache Ranger 监控 HDFS 权限变更，记录用户操作日志，便于追溯权限问题。


### 1.4 逐步项目 / 应用场景：逐渐扩展到更大规模


#### 阶段 1：单机伪分布式集群（测试 / 开发环境）

##### 1. 适用场景
- 本地测试 HDFS API（如 Java/Python 客户端开发）
- 验证小规模数据处理逻辑（如 10GB 以内数据的读写、Hive 表创建）

##### 2. 部署要点
- 单节点部署：NameNode、DataNode、SecondaryNameNode 部署在同一台机器
- 环境简化：关闭防火墙、SELinux，无需配置 SSH 免密（本地登录）
- 配置调整：dfs.replication=1（单节点无需多副本），fs.defaultFS=hdfs://localhost:9000

##### 3. 配置简化
- core-site.xml：仅配置fs.defaultFS与hadoop.tmp.dir
- hdfs-site.xml：仅配置dfs.replication与元数据 / 数据目录
- 无需配置workers文件（默认本地节点）

##### 4. 局限性
- 性能有限：单节点 CPU、内存、磁盘资源不足，无法模拟生产级吞吐量
- 无容错能力：节点故障导致集群不可用，数据丢失风险高


#### 阶段 2：小规模集群（10-20 节点，中小企业）

##### 1. 适用场景
- 日均数据量 100GB-1TB，支撑离线分析任务（如日报表生成、周度用户分析）
- 业务复杂度低，无实时数据处理需求

##### 2. 部署架构
- 控制节点：1 个 NameNode、1 个 SecondaryNameNode（部署在 2 台 8 核 16GB 机器）
- 数据节点：8-18 个 DataNode（每台 16 核 32GB，4-8 块 4TB HDD）
- 网络：千兆网卡，单机架部署

##### 3. 关键配置
- 副本数：2-3（核心数据 3 副本，非核心数据 2 副本）
- 块大小：128MB（适配中等文件，平衡 IO 与元数据量）
- DataNode 配置：dfs.datanode.data.dir设置为 4-8 个磁盘目录，分散 IO

##### 4. 监控重点
- NameNode：堆内存使用率（阈值≤85%）、RPC QPS（阈值≤5000）
- DataNode：磁盘使用率（阈值≤85%）、心跳状态（100% 在线）
- 集群：块丢失数（0）、Under-Replicated Blocks（≤100）


#### 阶段 3：中大规模集群（50-200 节点，互联网中型业务）

##### 1. 适用场景
- 日均数据量 1TB-10TB，支撑混合批流处理（如实时交易额统计、离线用户画像）
- 多业务线共享集群资源，需考虑资源隔离与权限控制

##### 2. 部署架构
- HA 架构：2 个 NameNode（主备，8 核 32GB 机器）、3 个 JournalNode（4 核 8GB 机器）、2 个 ZKFC（与 NameNode 同节点）
- 数据节点：46-196 个 DataNode（每台 24 核 64GB，8-12 块 8TB HDD/SSD 混合）
- 网络：万兆网卡，多机架部署（2-4 个机架）

##### 3. 配置升级
- 启用机架感知：编写机架脚本，配置dfs.network.topology.script.file.name，确保副本跨机架存储
- 块大小：256MB（适配大文件，提升读取吞吐量）
- NameNode 内存：16GB-32GB（根据文件数量调整，如千万级文件需 32GB 内存）
- 资源隔离：启用 YARN 资源队列，为不同业务线分配独立队列（如spark队列、hive队列）

##### 4. 运维优化
- 数据分区存储：按业务线（如/user/order、/user/user）、数据热度（热 / 温 / 冷）划分目录，配置不同存储策略
- 定期清理：通过 HDFS 配额（hdfs dfsadmin -setSpaceQuota）限制目录大小，定期清理过期数据
- 性能监控：用 Prometheus+Grafana 搭建监控平台，实时监控 IO、网络、内存指标


#### 阶段 4：超大规模集群（200 + 节点，大厂核心业务）

##### 1. 适用场景
- 日均数据量 10TB+，多业务共享存储（如电商交易、社交互动、视频推荐）
- 需支持跨地域容灾、细粒度权限控制、高并发访问

##### 2. 部署架构
- 联邦 + HA：多组 NameNode（每组 2 个主备节点），每组管理独立命名空间（如/user、/logs、/archive），3-5 个 JournalNode / 组
- 数据节点：200+DataNode（每台 32 核 128GB，12-16 块 10TB HDD/SSD）
- 网络：25G/100G 网卡，跨机房部署（主机房 + 备机房）

##### 3. 高级配置
- 存储策略：冷热数据分离，热数据（7 天内）存 SSD，温数据（7-30 天）存 HDD，冷数据（30 天 +）存归档存储（如 S3）
- 联邦命名空间隔离：不同业务线使用独立命名空间，避免相互影响
- 权限精细化控制：集成 Apache Ranger，实现目录级、文件级权限控制，支持 LDAP 认证
- 跨机房容灾：DataNode 跨机房部署，核心数据副本跨机房存储（如主机房 2 副本，备机房 1 副本）

##### 4. 运维挑战与应对
- 自动化部署：用 Ambari、Cloudera Manager 或自定义 Ansible 脚本实现集群自动化部署与升级
- 容灾备份：定期用distcp跨集群备份关键数据（如hadoop distcp hdfs://主集群:9000/user/hive/warehouse hdfs://备集群:9000/backup）
- 资源隔离：通过 YARN 标签（Label）为不同业务分配专属节点，避免资源抢占
- 故障自愈：开发脚本自动重启下线 DataNode、清理无效块，减少人工干预


## 四、深度进阶（Mastery）
### 1. 性能 / 效率优化：
HDFS 性能优化的核心目标是**降低 NameNode（NN）压力、提升 DataNode（DN）IO 效率、减少网络开销、优化存储成本**。

#### 1.1 元数据层优化（NameNode 性能核心）

NN 是 HDFS 元数据的“大脑”，其性能直接决定集群整体响应速度，优化重点是**减少内存占用、提升 RPC 处理能力**。
##### 1.1.1 内存配置与监控
- **核心原理**：NN 内存仅存储元数据（文件/目录结构、块映射），不存储数据本身，每百万文件/目录/块约占用 1GB 内存。
- **生产配置**：根据文件数量动态调整 JVM 堆内存（`hadoop-env.sh`）：
  ```bash
  # 千万级文件（1000万）配置 10-12GB 内存
  export HADOOP_NAMENODE_OPTS="-Xmx12g -Xms12g -XX:+UseG1GC $HADOOP_NAMENODE_OPTS"
  ```
- **概念辨析**：为何用 G1GC 而非 CMS？（G1GC 适合大内存（>8GB），减少 Full GC 停顿，避免 NN 因 GC 无响应）。
- **监控预警**：通过 Prometheus 监控 `namenode_heap_used` 指标，阈值设为 **≤85%**，超阈值触发告警（避免 OOM）。

##### 1.1.2 联邦（Federation）部署
- **解决痛点**：单 NN 无法承载超亿级文件（内存瓶颈+RPC 瓶颈），联邦通过“多 NN 拆分命名空间”实现水平扩展。
- **核心设计**：
  - 每个 NN 管理独立命名空间（如 `nn1` 管 `/user`，`nn2` 管 `/logs`，`nn3` 管 `/warehouse`）。
  - 所有 NN 共享 DN 存储资源（DN 向所有 NN 注册，存储多命名空间的块）。
- **生产配置**：在 `core-site.xml` 中配置客户端路由（基于路径匹配 NN）：
  ```xml
  <property>
    <name>fs.defaultFS</name>
    <value>hdfs://nameservice1</value> <!-- 联邦服务名 -->
  </property>
  <property>
    <name>dfs.nameservices</name>
    <value>nameservice1</value>
  </property>
  <property>
    <name>dfs.namenode.rpc-address.nameservice1.nn1</name>
    <value>nn1:9000</value> <!-- /user 对应 NN -->
  </property>
  <property>
    <name>dfs.namenode.rpc-address.nameservice1.nn2</name>
    <value>nn2:9000</value> <!-- /logs 对应 NN -->
  </property>
  <!-- 路径路由规则 -->
  <property>
    <name>dfs.federation.router.map</name>
    <value>/user->nn1,/logs->nn2,/warehouse->nn3</value>
  </property>
  ```
- **概念辨析**：联邦与 HA 的区别？（HA 是单命名空间的主备容错，联邦是多命名空间的水平扩展，二者可结合使用）。

##### 1.1.3 元数据操作优化

- **减少 RPC 调用**：客户端批量操作（如 `hdfs dfs -put` 批量上传而非单文件上传），避免频繁请求 NN。
- **关闭冗余元数据**：禁用不必要的元数据记录（如 `dfs.namenode.inode.attributes.provider.class` 关闭额外inode属性，减少内存占用）。
- **FsImage 合并优化**：调整 SNN 合并周期（`dfs.namenode.checkpoint.period`，默认 3600 秒），避免合并时占用 NN 资源；生产建议设为 **7200 秒（2小时）**，并在凌晨低峰期执行。


#### 1.2 读写性能优化（DataNode 与网络核心）
HDFS 读写性能瓶颈多集中在 **DN 磁盘 IO、网络带宽、客户端策略**，优化需针对性定位瓶颈（用 `iostat`、`iftop`、NN/DN Web UI 监控）。

##### 1.2.1 DataNode 磁盘 IO 优化
- **多磁盘分散 IO**：
  - 核心配置：`dfs.datanode.data.dir` 设为多个独立磁盘目录（如 `/data1/dn,/data2/dn,/data3/dn`），避免单磁盘 IO 过载。
  - 原理：DN 会将不同块写入不同磁盘，并行处理读写请求（HDD 推荐 4-8 块，SSD 推荐 2-4 块）。
- **存储介质分层**：
  - 热数据（如最近 7 天的计算数据）存 SSD，配置 `dfs.storage.policy.enabled=true` 并设置策略 `BlockStoragePolicy.HOT`。
  - 冷数据（如 30 天前的归档数据）存 HDD，策略设为 `BlockStoragePolicy.COLD`。
  - 生产命令：`hdfs storagepolicies -setStoragePolicy /user/hotdata HOT`。
- **IO 调度算法**：
  - HDD 推荐 `mq-deadline`（适合批量顺序 IO，HDFS 主要场景）：`echo mq-deadline > /sys/block/sda/queue/scheduler`。
  - SSD 推荐 `noop`（减少 CPU 开销，SSD 随机 IO 性能已足够）：`echo noop > /sys/block/sdb/queue/scheduler`。
- **优化磁盘配置**:
  -   **磁盘选择**: 使用多块磁盘并配置为 **JBOD (Just a Bunch Of Disks)** 模式，而不是 RAID0。HDFS 的副本机制本身已提供冗余，JBOD 能提供更好的 I/O 并行度和故障隔离。
  -   **目录配置**: 在 `hdfs-site.xml` 中为 `dfs.datanode.data.dir` 配置多个用逗号分隔的磁盘路径。

- **中央缓存管理（Centralized Cache Management）**：
  - **核心配置**：启用 NameNode 缓存协调机制，`dfs.namenode.path.based.cache.block.map.enable=true`；设置 DataNode 缓存内存上限 `dfs.datanode.max.locked.memory=16g`（根据节点内存调整）。
  - **原理**：由 NameNode 统一管理热点数据缓存策略，通过 CacheManager 识别高频访问块，将其锁定在 DataNode 的 off-heap 内存中（避免 JVM GC 影响），直接从内存响应读请求，减少磁盘 IO 开销。
  - **适用场景**：频繁访问的小文件（如维度表）、实时计算依赖的事实表、用户画像等热点数据。
  - **操作命令**：创建缓存池 `hdfs cacheadmin -addPool hotdataPool`；设置目录缓存 `hdfs cacheadmin -addCacheDirective -path /user/hotdata -pool hotdataPool -replication 2`。

##### 1.2.2 网络优化

- **升级网络硬件**：
  - 核心节点（NN、JN、核心 DN）用万兆网卡（10Gbps），普通 DN 用千兆网卡（1Gbps），避免网络带宽成为瓶颈。
  - 机架内用 40Gbps 交换机，跨机架用 100Gbps 核心交换机，减少跨机架 IO 延迟。
- **启用机架感知**：
  - 原理：NN 根据 DN 所在机架分配副本（默认 3 副本：1 个本地机架，1 个同机房其他机架，1 个跨机房机架），减少跨机架数据传输。
  - 配置：在 `core-site.xml` 中指定机架映射类：
    ```xml
    <property>
      <name>net.topology.node.switch.mapping.impl</name>
      <value>org.apache.hadoop.net.ScriptBasedMapping</value>
    </property>
    <property>
      <name>net.topology.script.file.name</name>
      <value>/etc/hadoop/rack-topology.sh</value> <!-- 自定义机架映射脚本 -->
    </property>
    ```
- **调大 TCP 缓冲区**：
  - 解决网络小包传输效率低的问题，修改 Linux 内核参数（`/etc/sysctl.conf`）：
    ```bash
    net.core.somaxconn = 1024  # 最大 TCP 连接队列
    net.ipv4.tcp_wmem = 4096 65536 16777216  # TCP 写缓冲区（最小/默认/最大）
    net.ipv4.tcp_rmem = 4096 65536 16777216  # TCP 读缓冲区（最小/默认/最大）
    ```
  - 生效命令：`sysctl -p`。

##### 1.2.3 客户端读写优化
- **多线程并行操作**：
  - 上传/下载大文件时用多线程（如 Java API 用 `ExecutorService` 创建 5-10 线程池），避免单线程瓶颈。
  - 示例（批量上传）：
    ```java
    ExecutorService executor = Executors.newFixedThreadPool(8);
    List<String> localFiles = Arrays.asList("/local/file1", "/local/file2");
    for (String local : localFiles) {
      executor.submit(() -> hdfsClient.copyFromLocalFile(new Path(local), new Path("/hdfs/path/")));
    }
    executor.shutdown();
    ```
- **预读取与块大小调整**：
  - 预读取：`dfs.client.read.prefetch.size` 设为 **256MB**（默认 128MB），客户端提前读取后续块，减少 IO 等待。
  - 块大小：大文件（如 >1GB）设为 **256MB**（默认 128MB），减少块数量（降低 NN 内存占用）和 Map 任务数（提升计算效率）；命令：`hdfs dfs -D dfs.blocksize=268435456 -put largefile /hdfs/path/`。
- **关闭客户端缓存**：
  - 小文件读写时禁用客户端缓存（`dfs.client.read.shortcircuit=false`），避免缓存占用内存；大文件读写启用（`true`），提升重复读取效率。


#### 1.3 存储优化（成本与效率平衡）
HDFS 默认 3 副本存储（开销 300%），生产中需通过 **EC 纠删码、冷数据归档** 降低成本，同时保证数据可靠性。

##### 1.3.1 Erasure Coding（EC 纠删码）
- **核心优势**：替代传统副本，用“数据块+校验块”实现容错，存储开销从 300% 降至 150%（如 RS-6-3：6 数据块+3 校验块，总 9 块，开销 9/6=150%）。
- **生产配置（Hadoop 3.x 稳定版）**：
  1. 启用 EC：`hdfs ec -enablePolicy -policy RS-6-3-1024k`。
  2. 为目录设置 EC 策略：`hdfs ec -setPolicy -path /user/colddata -policy RS-6-3-1024k`。
  3. 验证：`hdfs ec -getPolicy -path /user/colddata`。
- **注意事项**：
  - EC 适合冷数据（读写频率低），因重建块需计算校验块（CPU 开销高）；热数据仍用 3 副本。
  - JN 节点需 ≥3 个（EC 元数据依赖 JN 同步），DN 节点数 ≥ 校验块数+1（如 RS-6-3 需 DN ≥4）。
- **概念辨析**：EC 与副本的区别？（副本读效率高、无 CPU 开销，适合热数据；EC 存储成本低、CPU 开销高，适合冷数据）。

##### 1.3.2 冷数据归档
- **场景**：超过 90 天的冷数据（如历史日志、归档报表），几乎不读写，需进一步降低存储成本。
- **方案**：
  1. 先对冷数据启用 EC（RS-6-3），再迁移到低成本存储（如 SATA HDD，比 SSD 便宜 50%）。
  2. 用 `hdfs archive` 归档小文件（如将 1000 个小文件打包为 1 个 HAR 文件），减少 NN 内存占用。
  - 归档命令：`hadoop archive -archiveName colddata.har -p /user/colddata/smallfiles /user/colddata/har`。
- **恢复**：读取 HAR 文件：`hdfs dfs -cat har:///user/colddata/har/colddata.har/file1.txt`。

##### 1.3.3 数据生命周期管理
- **生产配置**：用 Apache Ranger 或 HDFS 自带的 `StoragePolicy` 实现自动分层：
  1. 热数据（0-7 天）：SSD + 3 副本。
  2. 温数据（7-30 天）：HDD + 2 副本。
  3. 冷数据（30+ 天）：SATA HDD + EC（RS-6-3）。
- **自动执行**：通过 Crontab 每日执行脚本，示例：
  ```bash
  # 将 30 天前的数据设为 EC 策略
  find /user/data -mtime +30 | xargs -I {} hdfs ec -setPolicy -path {} -policy RS-6-3-1024k
  ```

#### 1.4 小文件优化（NN 内存减负核心）
小文件（<128MB）是 HDFS 天敌，每 1 个小文件占用 NN 约 150B 内存，千万级小文件会耗尽 NN 内存，优化需从“源头合并+存量治理”双管齐下。

##### 1.4.1 源头合并（预防为主）
- **日志采集（Flume）**：配置滚动策略，控制文件大小：
  ```properties
  hdfs.rollSize = 134217728  # 128MB 滚动（达到大小生成新文件）
  hdfs.rollInterval = 3600   # 1 小时滚动（超时生成新文件，取二者最小值）
  hdfs.rollCount = 0         # 禁用行数滚动
  ```
- **计算输出（Spark/Flink）**：
  - Spark 输出时用 `coalesce`（不 shuffle）合并分区：`df.coalesce(10).write.parquet("/output")`（10 个分区=10 个文件，每个约 128MB）。
  - Flink 输出用 `setParallelism(5)` 控制并行度，避免过多小文件。
- **应用写入**：客户端先本地合并小文件（如用缓冲流，达到 128MB 后再上传），禁止单文件 <1MB 直接写入 HDFS。

##### 1.4.2 存量治理（已存在小文件）
- **Spark 批量合并**：
  ```scala
  val spark = SparkSession.builder().appName("MergeSmallFiles").getOrCreate()
  // 读取小文件（支持 text/parquet/csv）
  val smallFiles = spark.read.text("/user/smallfiles/*")
  // 合并为 256MB 大文件（按总数据量估算分区数，如 10GB 数据设 40 分区）
  smallFiles.repartition(40).write.mode("overwrite").text("/user/largefiles")
  // 删除原小文件
  spark.sparkContext.hadoopConfiguration.set("fs.hdfs.impl", classOf[org.apache.hadoop.hdfs.DistributedFileSystem].getName)
  val hdfs = org.apache.hadoop.fs.FileSystem.get(spark.sparkContext.hadoopConfiguration)
  hdfs.delete(new org.apache.hadoop.fs.Path("/user/smallfiles"), true)
  ```
- **HAR 归档**：适合只读小文件（如历史日志），命令：
  ```bash
  # 创建 HAR 文件（源路径 /user/smallfiles，目标路径 /user/har）
  hadoop archive -archiveName smallfiles.har -p /user/smallfiles /user/har
  # 删除原小文件
  hdfs dfs -rm -r /user/smallfiles
  ```
- **HBase 存储**：超亿级小文件（如传感器数据）用 HBase，HBase 将小文件合并为 HFile（大文件），仅需 NN 存储 HFile 元数据，大幅减少 NN 压力。


### 2. 容错 / 稳定性 / 稳健性：应对不确定性
HDFS 设计的核心目标之一是**高容错**，通过“主备冗余、副本机制、块检测、元数据备份”应对硬件故障（磁盘损坏、节点宕机）和软件异常（进程崩溃、网络中断），是生产集群稳定运行的基石，也是面试必问内容。

#### 2.1 NameNode 容错（避免单点故障）
NN 是 HDFS 单点风险最高的组件，容错方案分 **非 HA 场景（应急）** 和 **HA 场景（根治）**。

##### 2.1.1 非 HA 场景：SecondaryNameNode（SNN）应急恢复
- **SNN 作用**：并非备用 NN，仅负责**合并 FsImage 和 Edits**，减少 NN 启动时间；故障时可作为元数据备份恢复。
- **恢复步骤（NN 宕机后）**：
  1. 定位故障：查看 NN 日志（`$HADOOP_HOME/logs/hadoop-*-namenode-*.log`），确认是进程崩溃还是节点故障。
  2. 复制 SNN 元数据：若节点不可恢复，将 SNN 的元数据目录（`dfs.namenode.checkpoint.dir`）复制到新 NN 节点：
     ```bash
     scp -r snn1:/data/hadoop/snn/* nn-new:/data/hadoop/namenode/
     ```
  3. 重启 NN：`hdfs --daemon start namenode`。
- **局限性**：恢复后元数据可能丢失（SNN 合并周期内的 Edits 未同步），仅适合测试/小规模集群；生产必须用 HA。

##### 2.1.2 HA 场景：主备 NN + JournalNode + ZKFC（根治单点故障）
- **核心组件**：
  - 2 个 NN（主/备）：主 NN 处理读写请求，备 NN 实时同步元数据，主宕机后备立即接管。
  - 3 个 JournalNode（JN）：存储 Edits 日志（主 NN 写入，备 NN 读取），保证元数据同步（JN 需 ≥3，基于多数派协议，只要 ≥2 个 JN 存活即可）。
  - ZKFC（ZK Failover Controller）：每个 NN 部署 1 个 ZKFC，监控 NN 状态，主宕机时触发备切换（需配置 SSH 隔离，防止脑裂）。
- **故障切换流程**：
  1. 主 NN 宕机（如进程崩溃、网络中断）。
  2. 主 NN 的 ZKFC 失去心跳，ZK 释放主锁。
  3. 备 NN 的 ZKFC 检测到主锁释放，尝试获取主锁并执行“隔离主 NN”（SSH 杀死主 NN 进程，防止脑裂）。
  4. 备 NN 切换为“主”，读取 JN 最新 Edits 合并到 FsImage，开始处理客户端请求。
- **生产配置（关键参数 `hdfs-site.xml`）**：
  ```xml
  <!-- 1. HA 集群名 -->
  <property>
    <name>dfs.nameservices</name>
    <value>hdfs-ha</value>
  </property>
  <!-- 2. 主备 NN 节点 -->
  <property>
    <name>dfs.ha.namenodes.hdfs-ha</name>
    <value>nn1,nn2</value>
  </property>
  <!-- 3. 主 NN RPC 地址（客户端通信） -->
  <property>
    <name>dfs.namenode.rpc-address.hdfs-ha.nn1</name>
    <value>nn1:9000</value>
  </property>
  <!-- 4. 备 NN RPC 地址 -->
  <property>
    <name>dfs.namenode.rpc-address.hdfs-ha.nn2</name>
    <value>nn2:9000</value>
  </property>
  <!-- 5. JN 集群（存储 Edits） -->
  <property>
    <name>dfs.namenode.shared.edits.dir</name>
    <value>qjournal://jn1:8485;jn2:8485;jn3:8485/hdfs-ha</value>
  </property>
  <!-- 6. 故障切换代理（客户端自动发现主 NN） -->
  <property>
    <name>dfs.client.failover.proxy.provider.hdfs-ha</name>
    <value>org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider</value>
  </property>
  <!-- 7. 隔离机制（防止脑裂） -->
  <property>
    <name>dfs.ha.fencing.methods</name>
    <value>sshfence</value> <!-- SSH 登录主 NN 杀死进程 -->
  </property>
  <property>
    <name>dfs.ha.fencing.ssh.private-key-files</name>
    <value>/root/.ssh/id_rsa</value> <!-- SSH 私钥 -->
  </property>
  ```
- **概念辨析**：HA 中如何防止脑裂？（1. SSH 隔离：杀死旧主 NN 进程；2. JN 隔离：旧主 NN 无法写入 JN Edits，无法处理请求；3. 磁盘隔离：旧主 NN 无法访问元数据目录）。

##### 2.1.3 元数据备份（双重保险）

- **定期备份 FsImage**：通过 Crontab 每日凌晨执行 `hdfs dfsadmin -fetchImage /backup/hdfs/$(date +%Y%m%d)`，将 FsImage 备份到独立节点（如备份服务器），防止 HA 双 NN 同时故障。
- **备份策略**：保留最近 7 天的备份，超过 7 天自动删除（`find /backup/hdfs -mtime +7 -delete`）。
- **恢复测试**：每月一次恢复测试，确保备份可用（将备份 FsImage 复制到测试 NN 节点，启动 NN 验证元数据完整性）。


#### 2.2 DataNode 容错（保证数据可靠性）
DN 负责存储块数据，容错重点是**检测节点/磁盘故障、自动恢复副本**。

##### 2.2.1 节点故障检测与恢复
- **心跳机制**：
  - DN 每 3 秒向 NN 发送心跳（`dfs.datanode.heartbeat.interval=3`），携带节点状态和块信息。
  - NN 若 10 分钟（`dfs.namenode.heartbeat.recheck-interval=300000`，5 分钟×2）未收到心跳，标记 DN 为 `Dead`。
- **副本恢复流程**：
  1. NN 检测到 `Dead` DN 后，统计该 DN 上的块及剩余副本数。
  2. 对副本数 < 配置值（`dfs.replication`）的块，NN 调度健康 DN 从其他副本复制块，直至达到预期副本数。
  3. 示例：某块在 DN1（Dead）、DN2、DN3 存储，副本数从 3 变为 2，NN 会让 DN4 从 DN2 复制该块，恢复为 3 副本。
- **生产监控**：通过 Prometheus 监控 `datanode_dead_count` 指标，`Dead` DN 数 >0 立即告警，排查故障（网络/硬件/进程）。

##### 2.2.2 磁盘故障检测与恢复
- **块扫描机制**：
  - DN 每 3 周（`dfs.datanode.scan.period.hours=504`）扫描本地磁盘上的块，通过 CRC 校验检测块损坏（每个块对应 `blk_xxx.meta` 文件存储 CRC 值）。
  - 若检测到块损坏，DN 向 NN 上报 `BlockCorruptEvent`，NN 标记该块为“损坏”。
- **损坏块恢复流程**：
  1. NN 收到损坏报告后，检查该块的其他副本（如存在 DN2、DN3 的健康副本）。
  2. 调度 DN4 从 DN2 复制健康块，替换损坏块。
  3. 复制完成后，NN 标记损坏块为“已修复”，DN 删除本地损坏块文件。
- **生产优化**：将扫描周期缩短至 1 周（`dfs.datanode.scan.period.hours=168`），提前发现损坏块；同时监控 `datanode_corrupt_blocks` 指标，损坏块数 >10 触发告警。

##### 2.2.3 磁盘下线（避免故障扩散）
- **场景**：DN 某块磁盘使用率 >95% 或出现坏道（`dmesg` 日志显示 `IO error`），需下线磁盘避免影响其他块。
- **下线步骤**：
  1. 在 `hdfs-site.xml` 中移除该磁盘路径（如从 `dfs.datanode.data.dir=/data1/dn,/data2/dn` 改为 `/data1/dn`）。
  2. 重启 DN：`hdfs --daemon stop datanode && hdfs --daemon start datanode`。
  3. 验证：`hdfs dfsadmin -report` 查看 DN 存储目录，确认下线磁盘已移除。
  4. 清理下线磁盘：在 DN 节点执行 `rm -rf /data2/dn/*`（确保数据已复制到其他磁盘）。


#### 2.3 集群稳定性保障（生产运维核心）
除组件容错外，需通过 **监控告警、资源限制、故障演练** 保障集群长期稳定运行。

##### 2.3.1 全链路监控告警
- **核心监控指标**：
  | 组件   | 关键指标                          | 阈值          | 告警方式       |
  |--------|-----------------------------------|---------------|----------------|
  | NN     | 堆内存使用率、RPC QPS、Missing Blocks | ≤85%、≤8000、=0 | 短信+邮件      |
  | DN     | 磁盘使用率、Dead 节点数、Corrupt Blocks | ≤85%、=0、≤10 | 短信+邮件      |
  | JN     | 进程状态、Edits 同步延迟          | 运行中、≤1s   | 邮件           |
  | 网络   | 带宽使用率、丢包率                | ≤85%、≤0.1%   | 短信           |
- **监控工具**：Prometheus + Grafana（可视化）+ Alertmanager（告警），配置 Dashboard 展示集群整体状态（如 NN 内存趋势、DN 存活数、块健康度）。
- **日志监控**：用 ELK（Elasticsearch+Logstash+Kibana）收集 NN/DN/JN 日志，设置关键词告警（如 `OutOfMemoryError`、`BlockMissingException`），实时定位异常。

##### 2.3.2 资源限制与隔离
- **JVM 资源限制**：
  - NN：`-Xmx12g -Xms12g -XX:MetaspaceSize=256m -XX:MaxMetaspaceSize=512m`（避免内存溢出）。
  - DN：`-Xmx4g -Xms4g`（DN 内存需求低，无需过大）。
  - JN：`-Xmx2g -Xms2g`（仅存储 Edits，内存需求低）。
- **CPU 隔离**：用 `cgroups` 限制 NN/DN 进程的 CPU 使用率（如 NN 最多用 4 核），避免被其他进程（如 Spark 任务）抢占 CPU 资源。
- **网络隔离**：在交换机配置 VLAN，将 HDFS 节点（NN/DN/JN）与计算节点（Spark/Flink）分开，避免计算任务占用 HDFS 网络带宽。

##### 2.3.3 故障演练（提前暴露问题）
- **演练频率**：每季度一次，模拟生产中高频故障场景。
- **核心场景**：
  1. NN 主备切换：手动停止主 NN 进程，观察备 NN 是否在 30 秒内切换为“主”，客户端是否无感知（读写不中断）。
  2. DN 宕机：关闭某 DN 节点，观察 NN 是否在 10 分钟内标记其为 `Dead`，副本是否自动恢复。
  3. 块损坏：手动删除 DN 上的块文件（如 `rm /data1/dn/current/blk_1073741824`），观察 DN 是否检测到损坏，NN 是否调度恢复。
- **演练目标**：确保故障切换时间 <1 分钟，数据无丢失，业务无中断。


#### 2.4 快照容错（数据备份与回滚）
HDFS 快照（Snapshots）是**数据层面的容错手段**，通过增量式备份实现重要目录的保护，核心用于应对误操作、数据损坏，同时支持快速回滚，是生产中保障数据安全性的关键配置。

##### 2.4.1 核心作用
- **防误操作**：避免人工误删/误改重要数据（如 Hive 表目录、数仓核心分区），快照可恢复到操作前状态。
- **数据备份**：替代传统全量拷贝，增量快照仅记录数据变化，占用空间小、创建效率高（毫秒级）。
- **版本回溯**：支持保留多版本快照，可回滚到任意历史快照点（如回滚到“昨天 0 点”的数仓状态）。

##### 2.4.2 工作原理
- **增量存储**：快照创建时不复制全量数据，仅记录目录元数据（如文件列表、块映射）；当数据块被修改/删除时，HDFS 会先将旧块“冻结”并关联到快照，再写入新块——即快照仅存储“变化的差异数据”，而非全量。
- **无性能影响**：快照创建、查询操作不阻塞目录的正常读写；仅当数据首次被修改时，会有轻微 IO 开销（冻结旧块），后续修改无额外影响。

##### 2.4.3 配置与操作步骤
- **前提配置**：HDFS 目录默认不允许创建快照，需先启用目录快照功能：
  ```bash
  # 启用 /hive/warehouse（Hive 表存储目录）的快照功能
  hdfs dfsadmin -allowSnapshot /hive/warehouse
  # 验证启用状态（返回 "Snapshot is allowed on /hive/warehouse"）
  hdfs dfsadmin -querySnapshot /hive/warehouse
  ```

- **核心操作命令**：
  | 操作类型   | 命令示例                                                                 | 说明                                  |
  |------------|--------------------------------------------------------------------------|---------------------------------------|
  | 创建快照   | `hdfs dfs -createSnapshot /hive/warehouse wh_snapshot_20240520`          | 创建名为“wh_snapshot_20240520”的快照  |
  | 查看快照   | `hdfs dfs -lsSnapshottableDir /hive/warehouse`                           | 查看目录下所有快照                    |
  | 回滚快照   | `hdfs dfs -rollbackSnapshot /hive/warehouse/wh_snapshot_20240520`        | 将目录回滚到指定快照状态（需目录无写操作） |
  | 删除快照   | `hdfs dfs -deleteSnapshot /hive/warehouse wh_snapshot_20240520`          | 删除过期快照，释放关联的差异数据空间  |
  | 比较快照差异   | `hdfs snapshotDiff /user/critical_data wh_snapshot_20240520 wh_snapshot_20240521`          | 分析两个快照之间的文件系统变化  |
  | 监控快照占用   | `hdfs dfs -du -h /user/critical_data/.snapshot`          | 监控快照占用空间  |
  
- **自动化快照**：生产中通过 Crontab 定时创建快照，避免人工遗漏：
  ```bash
  # 编辑定时任务：每天 0 点为 /hive/warehouse 创建快照
  crontab -e
  # 添加如下内容（快照名含日期，便于识别）
  0 0 * * * hdfs dfs -createSnapshot /hive/warehouse wh_snapshot_$(date +%Y%m%d)
  ```

##### 2.4.4 注意事项
- **目录限制**：不支持嵌套快照——若父目录已启用快照，其子目录无法单独启用快照（反之亦然）。
- **删除约束**：若目录存在快照，删除目录前必须先删除所有快照（否则报错“Cannot delete directory with snapshots”）。
- **空间管理**：快照关联的“冻结旧块”仅在快照删除后才会被回收，需定期清理过期快照（如保留最近 7 天），避免占用过多存储：
  ```bash
  # 清理 /hive/warehouse 下 7 天前的快照（需自定义脚本遍历快照名）
  hdfs dfs -lsSnapshottableDir /hive/warehouse | grep "wh_snapshot_" | awk -v d=$(date -d "7 days ago" +%Y%m%d) '$2 < d {print $1}' | xargs -I {} hdfs dfs -deleteSnapshot /hive/warehouse {}
  ```
- **回滚前提**：回滚操作需确保目录无活跃写请求（如停止 Hive 任务、Spark 写入），否则回滚失败。


### 3. 源码研究：

#### 3.1 NameNode 元数据管理（FsImage + Edits）
NN 元数据存储在 **FsImage（全量）** 和 **Edits（增量）** 中，源码核心在 `org.apache.hadoop.hdfs.server.namenode` 包。

##### 3.1.1 FsImage 与 Edits 核心流程
- **FsImage**：存储某一时刻的全量元数据（文件/目录结构、块映射、权限），以二进制格式存储在 `dfs.namenode.name.dir` 目录（如 `fsimage_0000000000000001234`）。
- **Edits**：存储 FsImage 生成后的增量元数据操作（如创建文件、删除目录、修改权限），以日志格式存储（如 `edits_0000000000000001235-0000000000000001240`）。
- **核心流程源码逻辑**：
  1. **元数据写入**：
     - 客户端发起写操作（如 `hdfs dfs -mkdir /test`），NN 先检查权限/空间，通过后生成 Edits 记录（`FSEditLog.logEdit()` 方法），写入本地 Edits 文件和 JN（HA 场景）。
     - Edits 写入成功后，更新 NN 内存中的元数据（`FSNamesystem` 类维护内存元数据），再向客户端返回成功。
  2. **FsImage 合并（Checkpoint）**：
     - 触发条件：① 距离上次合并超过 `dfs.namenode.checkpoint.period`（3600 秒）；② Edits 大小超过 `dfs.namenode.checkpoint.size`（64MB）。
     - 合并流程（SNN 或备 NN 执行）：
       a. SNN 向主 NN 发送 `getEditLogManifest` 请求，获取待合并的 Edits 文件。
       b. SNN 加载本地 FsImage（全量），逐行解析 Edits（增量），合并为新 FsImage（`fsimage_0000000000000001241`）。
       c. SNN 将新 FsImage 发送给主 NN，主 NN 替换旧 FsImage 并删除已合并的 Edits。
- **概念辨析**：为何 Edits 要先写后更新内存？（保证“日志先行（Write-Ahead Log）”，防止 NN 宕机时元数据丢失，Edits 是元数据的唯一持久化增量记录）。

##### 3.1.2 元数据加载流程（NN 启动时）
- **源码入口**：`NameNode.format()`（首次启动格式化）和 `NameNode.loadNamesystem()`（非首次启动加载）。
- **加载步骤**：
  1. NN 启动时，先读取 `dfs.namenode.name.dir` 目录下的最新 FsImage（最大序号的 `fsimage_xxx`）。
  2. 加载 FsImage 到内存（`FSNamesystem` 的 `dir` 字段，类型为 `INodeDirectory`，存储目录树结构）。
  3. 读取 FsImage 之后生成的所有 Edits 文件（如 `edits_1241-1250`），逐行解析并更新内存元数据。
  4. 加载完成后，NN 进入“安全模式（Safe Mode）”，等待 DN 上报块信息（`BlockReport`）。
  5. 当 NN 收到 ≥99% 的块报告且副本数达标后，退出安全模式，开始处理客户端请求。
- **生产问题定位**：若 NN 启动后一直卡在安全模式，查看日志是否有“块缺失过多”（`UnderReplicated Blocks` 占比 >1%），需先恢复缺失块。


#### 3.2 DataNode 块存储与上报
DN 源码核心在 `org.apache.hadoop.hdfs.server.datanode` 包，重点是 **块接收、块上报、心跳机制**。

##### 3.2.1 块接收流程（客户端上传文件）
- **源码入口**：`DataXceiverService`（DN 监听 9866 端口，处理客户端/其他 DN 的块传输请求）。
- **接收步骤**：
  1. 客户端上传文件时，NN 分配块 ID 和存储 DN（如 DN1、DN2、DN3），返回给客户端。
  2. 客户端向 DN1 发起块写入请求（`OP_WRITE_BLOCK`），DN1 与 DN2、DN3 建立 pipeline 连接（DN1→DN2→DN3）。
  3. 客户端将文件切分为 64KB 数据包（`Packet`），发送给 DN1。
  4. DN1 接收数据包后，先写入本地临时文件（`blk_xxx.tmp`），再转发给 DN2；DN2 同理转发给 DN3。
  5. 每个 DN 接收完所有数据包后，向客户端返回 ACK（确认）。
  6. 客户端收到所有 DN 的 ACK 后，通知 NN 块写入完成，NN 更新元数据。
- **生产问题**：若上传文件时报“pipeline 断开”，查看 DN 日志是否有网络超时（`SocketTimeoutException`），需检查 DN 之间的网络连通性。

##### 3.2.2 块上报机制（BlockReport）
- **核心作用**：DN 向 NN 上报本地存储的块信息，NN 据此维护“块→DN”的映射关系。
- **上报类型与源码逻辑**：
  1. **全量块上报（Initial BlockReport）**：DN 启动时，扫描 `dfs.datanode.data.dir` 目录下的所有块，生成全量块报告（`BlockReport`），通过 `BPServiceActor.sendBlockReport()` 发送给 NN。
  2. **增量块上报（Incremental BlockReport）**：DN 运行中，若块有新增/删除/损坏，通过 `BlockReport` 增量上报（默认每 6 小时一次，`dfs.datanode.blockreport.intervalMsec=21600000`）。
  3. **NN 处理**：NN 接收块报告后，更新内存中的 `BlockManager`（维护块映射），并检查副本数是否达标（如不足则触发副本复制）。
- **概念辨析**：DN 为何要分全量和增量上报？（全量上报确保 NN 启动时获取完整块信息，增量上报减少网络开销，避免频繁发送全量数据）。


#### 3.3 HA 故障切换（ZKFC + JournalNode）
HA 切换的核心逻辑在 `org.apache.hadoop.hdfs.server.namenode.ha` 包，重点是 **ZKFC 监控与隔离、JN 元数据同步**。

##### 3.3.1 ZKFC 监控与主备切换
- **ZKFC 核心职责**：每个 NN 部署一个 ZKFC，负责监控 NN 状态、管理 ZK 锁、触发故障切换。
- **源码流程（主 NN 宕机后）**：
  1. **健康检测**：ZKFC 每 1 秒调用 `HealthMonitor.checkHealth()` 检查 NN 健康状态（如 RPC 是否可连接、NN 是否在安全模式外）。
  2. **主锁释放**：若主 NN 健康检测失败，ZKFC 释放 ZK 中的“主锁”节点（`/hadoop-ha/hdfs-ha/ActiveStandbyElectorLock`）。
  3. **备 NN 抢锁**：备 NN 的 ZKFC 检测到主锁释放，调用 `ActiveStandbyElector.tryToBecomeActive()` 尝试创建主锁节点，成功则成为“主候选者”。
  4. **隔离旧主**：备 ZKFC 执行隔离策略（如 SSH 隔离：`SSHFenceByTcpPort.fence()` 登录旧主 NN，杀死 NN 进程），防止脑裂。
  5. **切换主备**：备 ZKFC 调用 `HAContext.transitionToActive()`，将备 NN 切换为“Active”状态，同时通知 JN 切换主写节点。
  6. **客户端感知**：客户端通过 `ConfiguredFailoverProxyProvider` 自动发现新主 NN，无需修改配置。

##### 3.3.2 JournalNode 元数据同步
- **JN 核心作用**：存储 Edits 日志，实现主备 NN 元数据同步（主写从读）。
- **源码流程（主 NN 写入 Edits）**：
  1. 主 NN 生成 Edits 记录后，调用 `QJournal.writeEditRecords()` 向所有 JN 发送写入请求。
  2. JN 收到请求后，先写入本地磁盘的 Edits 文件（`/data/jn/hdfs-ha/current/edits_xxx`），再向主 NN 返回“写入成功”。
  3. 主 NN 收到 ≥ 半数 JN 的成功响应（如 3 个 JN 中 2 个成功），则认为 Edits 写入成功。
  4. 备 NN 调用 `QJournal.readEditRecords()` 从 JN 读取最新 Edits，实时更新本地内存元数据，确保与主 NN 一致。
- **概念辨析**：JN 为何需要 ≥3 个？（基于多数派协议，只要 ≥(N+1)/2 个 JN 存活，就能保证 Edits 写入和读取的一致性，3 个 JN 最多允许 1 个故障，5 个允许 2 个故障）。


#### 3.4 块损坏检测与恢复（DataNode + NameNode）
块损坏的检测与恢复是 HDFS 数据可靠性的关键，源码逻辑涉及 DN 块扫描和 NN 副本调度。

##### 3.4.1 DN 块扫描与损坏上报
- **源码入口**：`BlockScanner.scanBlock()`（DN 后台线程，每 3 周扫描一次块）。
- **扫描流程**：
  1. BlockScanner 线程遍历 DN 本地所有块，对每个块读取 `blk_xxx` 文件内容，计算 CRC32 校验值。
  2. 对比计算出的 CRC 值与 `blk_xxx.meta` 文件中存储的 CRC 值：
     - 一致：块健康，继续扫描下一个。
     - 不一致：块损坏，调用 `DataNode.reportCorruptBlock()` 向 NN 上报损坏块（携带块 ID 和 DN 信息）。
- **生产优化**：修改 `dfs.datanode.scan.threads`（默认 1）为 2-4，提升块扫描速度（需注意 CPU 开销）。

##### 3.4.2 NN 损坏块恢复
- **源码入口**：`BlockManager.handleCorruptBlock()`（NN 处理损坏块上报）。
- **恢复流程**：
  1. NN 收到损坏块报告后，将该块标记为 `CORRUPT`，并从内存中的块映射（`BlockManager`）中移除损坏的 DN 条目。
  2. 检查该块的剩余健康副本数：
     - 若 ≥ 配置副本数（`dfs.replication`）：无需处理，仅标记损坏。
     - 若 < 配置副本数：调用 `BlockManager.scheduleReplication()` 调度副本复制。
  3. 副本复制：NN 选择一个健康 DN（如 DN2）作为源，一个空闲 DN（如 DN4）作为目标，向 DN4 发送复制命令（`BlockCommand`）。
  4. DN4 从 DN2 复制块数据，完成后向 NN 上报块信息，NN 更新块映射，标记块为 `HEALTHY`。


#### 3.5 RPC 通信框架（进程间通信基石）
HDFS 各组件（NN/DN/JN/客户端）的通信完全依赖**自定义 RPC 框架**，其基于 Protobuf 实现序列化，兼具性能与兼容性，是理解分布式协作的前提。

##### 3.5.1 核心组件与设计
- **源码入口**：`org.apache.hadoop.ipc` 包（核心类：`RPC.Server`、`RPC.Client`、`ProtobufRpcEngine`）。
- **核心设计**：
  - **序列化协议**：默认使用 Protobuf（替代早期的 Writable），支持跨语言调用，序列化效率提升 30%+。
  - **通信模型**：基于 TCP 的请求-响应模式，客户端发送 `RpcRequest`，服务端返回 `RpcResponse`。
  - **服务暴露**：服务端通过 `RPC.Builder` 注册接口（如 `ClientProtocol` 是 NN 与客户端的通信接口），绑定端口并启动 `RPC.Server` 监听请求。

##### 3.5.2 调用流程（以客户端向 NN 发送请求为例）
1. **客户端 stub 生成**：通过 `ProtobufRpcEngine.getProxy()` 生成接口代理（如 `NameNodeProxies.createProxy()`），封装网络调用细节。
2. **请求序列化**：客户端将请求参数（如文件路径、操作类型）通过 Protobuf 序列化为字节流，封装为 `RpcRequestHeader` + 消息体。
3. **网络传输**：通过 `Netty` 或 `Socket` 发送请求到 NN 的 RPC 端口（默认 9000），等待响应。
4. **服务端处理**：NN 的 `RPC.Server` 线程池接收请求，反序列化后调用对应实现类（如 `NameNodeRpcServer`）的方法（如 `create()` 创建文件）。
5. **响应返回**：服务端将处理结果序列化，通过同样的链路返回给客户端，客户端反序列化后获取结果。

##### 3.5.3 关键优化点
- **连接复用**：客户端通过 `ConnectionPool` 复用 TCP 连接，避免频繁握手开销（`ipc.client.connection.maxidletime` 控制空闲超时）。
- **超时控制**：`ipc.client.timeout`（默认 60s）设置请求超时，防止客户端无限等待；服务端 `ipc.server.handler.queue.size` 控制请求队列长度，避免 OOM。


#### 3.6 NameNode 启动流程（元数据重建核心）
NN 启动的核心是**从持久化存储（FSImage + EditLog）重建内存元数据镜像**，过程涉及文件系统状态恢复、安全模式校验，是理解元数据一致性的关键。

##### 3.6.1 源码入口与核心类
- **入口方法**：`NameNode.main()` → `createNameNode()` → `initialize()`（初始化核心流程）。
- **核心类**：`FSNamesystem`（内存元数据管理）、`FSImage`（镜像文件操作）、`EditLog`（日志操作）、`NameNodeResourceChecker`（资源检查）。

##### 3.6.2 启动全流程
1. **初始化配置与安全检查**：
   - 加载 `hdfs-site.xml` 等配置，初始化 `Configuration` 对象。
   - 检查本地目录权限（`dfs.namenode.name.dir`）、磁盘空间是否充足（`dfs.namenode.resource.check` 启用检查）。

2. **元数据镜像加载（FSImage）**：
   - 调用 `FSImage.loadFSImage()`，从 `dfs.namenode.name.dir` 读取最新的 FSImage（如 `fsimage_0000000000000012345`）。
   - 解析 FSImage 到内存：重建 `INode` 树（文件/目录结构）、`BlockManager` 块映射（块与 DN 的关联）、权限信息等。

3. **EditLog 回放（日志合并）**：
   - 读取 FSImage 之后产生的所有 EditLog（如 `edits_0000000000000012346-0000000000000012350`）。
   - 逐条回放日志操作（如 `OP_CREATE`、`OP_DELETE`），将 FSImage 之后的元数据变更应用到内存镜像，确保内存状态与最新操作一致。

4. **进入安全模式（SafeMode）**：
   - 启动后自动进入安全模式，此时 NN 仅接收读请求，拒绝写请求。
   - 等待 DN 上报块信息（`BlockReport`），当满足“已上报块数 / 总块数 ≥ 0.999”（`dfs.namenode.safemode.threshold-pct`），自动退出安全模式。

5. **服务启动**：
   - 启动 RPC 服务（`NameNodeRpcServer`）和 HTTP 服务（Web UI），开始处理客户端请求。

##### 3.6.3 关键细节
- **FSImage 与 EditLog 版本兼容**：通过 `LayoutVersion` 控制，不同版本的 NN 无法加载不兼容的镜像/日志（避免升级故障）。
- **并行回放优化**：Hadoop 3.x 支持 EditLog 并行回放（`dfs.namenode.editlog.parallel.playback`），多线程处理日志，提升启动速度 50%+。


#### 3.7 数据写入流程（DFSOutputStream 核心逻辑）
HDFS 数据写入的可靠性依赖 `DFSOutputStream` 的 Pipeline 机制和应答确认，其核心是**保证数据在多副本间的一致性**，即使中途节点故障也能恢复。

##### 3.7.1 源码入口与核心类
- **入口方法**：`DFSClient.create()` → `DFSOutputStream` 初始化。
- **核心类**：`DFSOutputStream`（客户端写入流）、`DataStreamer`（数据发送线程）、`ResponseProcessor`（应答处理线程）、`PipelineAck`（管道应答）。

##### 3.7.2 写入全流程（以 3 副本为例）
1. **申请块与建立 Pipeline**：
   - 客户端向 NN 发送 `create` 请求，NN 在 `FSNamesystem` 中创建文件元数据（`INodeFile`），并分配第一个块（`Block`）及 3 个 DN 节点（如 DN1、DN2、DN3）。
   - 客户端收到块信息后，通过 RPC 与 DN1 建立连接，DN1 再与 DN2 建立连接，DN2 与 DN3 建立连接，形成“客户端→DN1→DN2→DN3”的 Pipeline。

2. **数据分块与发送**：
   - 客户端将文件数据分为 64KB 的 `Packet`（数据包），放入 `DataStreamer` 的内部队列（`dataQueue`）。
   - `DataStreamer` 线程从队列取出 Packet，按 Pipeline 顺序发送：先发送到 DN1，DN1 接收后转发给 DN2，DN2 转发给 DN3。

3. **应答确认（Ack）**：
   - 最后一个节点（DN3）接收 Packet 后，生成 `PipelineAck`（包含 Packet 校验和、状态），沿 Pipeline 反向返回（DN3→DN2→DN1→客户端）。
   - 客户端 `ResponseProcessor` 线程接收 Ack：
     - 成功：移除队列中的 Packet，继续发送下一个。
     - 失败：触发故障恢复（见 3.7.3）。

4. **块完成与文件关闭**：
   - 当块数据写满（达到 `dfs.blocksize`），客户端向 NN 发送 `completeBlock` 请求，NN 标记块为 `COMPLETE`。
   - 重复步骤 1-3 写入后续块，直至文件写完，客户端调用 `close()`，NN 标记文件为 `CLOSED`。

##### 3.7.3 故障恢复机制
- **单节点故障（如 DN2 宕机）**：
  1. 客户端检测到连接中断，`ResponseProcessor` 标记未确认的 Packet 为失败。
  2. 关闭当前 Pipeline，向 NN 上报 DN2 故障，NN 重新分配新 DN（如 DN4），建立新 Pipeline（DN1→DN4）。
  3. 重发失败的 Packet 到新 Pipeline，确保所有副本数据一致。
- **数据校验**：每个 Packet 携带 CRC 校验和，接收方验证通过才写入，避免网络传输错误。


#### 3.8 租约机制（Lease Recovery，数据一致性保障）
租约机制是 HDFS 解决**客户端写入中断导致的文件不一致**问题的核心，通过 NN 管理客户端对文件的“写入权限”，确保异常场景下数据可恢复。

##### 3.8.1 源码入口与核心类
- **入口类**：`LeaseManager`（NN 中管理租约）、`FSNamesystem.leaseManager`（租约操作入口）。
- **核心概念**：
  - **租约（Lease）**：客户端对文件的独占写入权限，包含客户端 ID、文件路径、租约期限（默认 60s，`dfs.lease.duration`）。
  - **软超时（Soft Limit）**：默认 30s（`dfs.lease.softlimit`），超时后客户端仍可续期；超过硬超时（即租约期限）则视为客户端异常。

##### 3.8.2 租约生命周期
1. **租约获取**：客户端调用 `create()` 或 `append()` 时，NN 的 `LeaseManager.addLease()` 为其创建租约，绑定客户端 ID 与文件。

2. **租约续约**：
   - 客户端每 10s（`dfs.client.lease.renewal.interval`）向 NN 发送 `renewLease` 请求，`LeaseManager.renewLease()` 刷新租约过期时间。
   - 正常写入期间，租约持续有效，其他客户端无法写入该文件（保证独占性）。

3. **租约释放**：
   - 客户端正常调用 `close()` 时，NN 调用 `LeaseManager.removeLease()` 释放租约，标记文件为 `CLOSED`。
   - 若客户端异常退出（如进程崩溃），无法续约，租约将在硬超时后过期。

##### 3.8.3 租约恢复流程（客户端异常后）
1. **检测过期租约**：NN 的 `LeaseManager` 后台线程（`LeaseChecker`）每 2s 扫描一次，发现硬超时的租约（`expiredLeases`）。

2. **确定恢复代理**：从文件的副本 DN 中选择一个作为“恢复代理”（如 DN1），负责协调其他副本一致。

3. **块同步与截断**：
   - 恢复代理对比所有副本的块数据，以最长的有效数据为准（截断无效尾部数据）。
   - 若块未写满（`UNDER_CONSTRUCTION`），恢复代理将其标记为 `COMPLETE`，并向 NN 上报最终块长度。

4. **租约清理**：NN 接收恢复完成的块信息，更新元数据，删除过期租约，文件变为可读状态。

##### 3.8.4 核心作用
- **防止多客户端冲突**：租约确保同一时间只有一个客户端写入文件，避免数据混乱。
- **解决写入中断**：即使客户端异常，NN 也能通过租约恢复使文件处于一致状态（无残缺数据）。


### 4. 版本差异 / 特性:当下市占率高版本、最新版本
Hadoop 版本主线分为 **2.x（稳定版，市占率 ~60%）** 和 **3.x（主流升级版，市占率 ~35%）**，4.x 处于实验阶段（生产暂不推荐）。本节聚焦 2.x 与 3.x 的核心差异、高频使用版本特性，以及升级注意事项（生产迁移重点）。

#### 4.1 Hadoop 2.x 核心特性（市占率最高，稳定可靠）
- **主流版本**：2.7.x（如 2.7.3、2.7.7）、2.8.x（2.8.5）、2.9.x（2.9.2），其中 **2.7.3** 是最经典版本（大量企业仍在使用）。
- **核心特性**：
  1. **HA 架构**：引入 2 个 NN（主备）+ JN + ZKFC，解决 NN 单点故障（但 EC 是实验性特性，不推荐生产使用）。
  2. **YARN 资源管理**：分离计算与存储，YARN 统一调度 Spark/Flink/Hive 等计算任务。
  3. **联邦（Federation）**：支持多 NN 拆分命名空间，但配置复杂（需手动维护路径路由）。
  4. **默认块大小**：128MB（HDD 场景优化，减少 NN 内存占用）。
  5. **局限性**：
     - 存储开销高（仅支持 3 副本，无稳定 EC）。
     - NN 内存限制（单 NN 最多支持千万级文件，超量需联邦）。
     - JDK 依赖：仅支持 JDK 7/8（不支持 JDK 9+）。
- **适用场景**：中小型集群（DN 数 < 500）、对稳定性要求极高、暂不考虑升级的企业（如金融、电信行业）。

#### 4.2 Hadoop 3.x 核心特性（主流升级方向，性价比高）
- **主流版本**：3.1.x（3.1.3）、3.2.x（3.2.4）、3.3.x（3.3.6，最新稳定版），其中 **3.2.4** 是企业升级首选（平衡稳定与新特性）。
- **核心特性（对比 2.x 新增/增强）**：
  1. **EC 纠删码（稳定版）**：
     - 2.x 中 EC 是实验性（`dfs.erasurecoding.enabled=false`），3.x 正式稳定，支持 RS-6-3、RS-3-2 等策略，存储开销从 300% 降至 150%。
     - 生产价值：冷数据存储成本降低 50%，适合 PB 级集群。
  2. **NN 联邦增强（RBF）**：
     - 引入 **Router-based Federation（RBF）**，替代 2.x 手动路径路由，通过 Router 节点自动将客户端请求转发到对应 NN（配置更简单，支持动态添加 NN）。
     - 配置示例（`core-site.xml`）：
       ```xml
       <property>
         <name>fs.defaultFS</name>
         <value>hdfs://router</value> <!-- Router 服务名 -->
       </property>
       <property>
         <name>dfs.router.nameservices</name>
         <value>nn1,nn2</value> <!-- 后端 NN 集群 -->
       </property>
       ```
  3. **JDK 支持升级**：
     - 支持 JDK 8/9/10/11（推荐 JDK 11，长期支持版），解决 2.x JDK 版本过时问题。
  4. **存储策略增强**：
     - 新增 `WARM` 存储策略（介于 HOT 和 COLD 之间），支持 SSD/HDD/SATA 三级存储分层，更灵活的热冷数据管理。
  5. **性能优化**：
     - NN 支持异步块汇报（`dfs.namenode.blockreport.async.enabled=true`），减少 NN RPC 压力。
     - DN 支持并行块扫描（`dfs.datanode.scan.threads=4`），提升块损坏检测速度。
     - 默认块大小：256MB（适应 SSD 场景，提升 IO 效率）。
  6. **云原生支持**：
     - 支持与 S3/Azure Blob 兼容的对象存储（如 `fs.s3a.impl` 配置），便于混合云部署。
- **适用场景**：中大型集群（DN 数 ≥ 500）、PB 级数据量（需 EC 降低成本）、追求新特性与性价比的企业（如互联网、大数据公司）。

#### 4.3 2.x 升级到 3.x 注意事项（生产迁移重点）
- **兼容性问题**：
  1. **API 变更**：部分过时 API 被移除（如 `org.apache.hadoop.hdfs.DistributedFileSystem` 的 `append` 方法签名变更），需修改应用代码。
  2. **配置变更**：
     - 2.x 中的 `dfs.namenode.secondary.http-address` 在 3.x 中改为 `dfs.namenode.secondary.http-address`（兼容，但推荐用新命名）。
     - EC 相关配置从 `dfs.erasurecoding.*` 改为 `dfs.ec.*`（需更新配置文件）。
  3. **JN 版本兼容**：2.x 的 JN 无法与 3.x 的 NN 通信，升级需先停集群，全量替换 JN 为 3.x 版本，再启动 NN。
- **升级步骤（生产推荐滚动升级）**：
  1. 环境准备：部署 3.x 集群（独立于 2.x 集群），安装 JDK 11，配置环境变量（`HADOOP_HOME`、`JAVA_HOME`）。
  2. 元数据迁移：
     - 在 2.x NN 执行 `hdfs dfsadmin -fetchImage /backup/fsimage_2x`，获取最新 FsImage。
     - 在 3.x NN 执行 `hdfs oiv -i /backup/fsimage_2x -o /backup/fsimage_3x -p XML`，转换 FsImage 格式。
     - 将转换后的 FsImage 复制到 3.x NN 的 `dfs.namenode.name.dir` 目录，启动 3.x NN。
  3. 数据迁移：用 `distcp` 工具将 2.x HDFS 数据同步到 3.x HDFS：
     ```bash
     hdfs distcp hdfs://nn2x:9000/ /  # 从 2.x 同步所有数据到 3.x
     ```
  4. 验证：同步完成后，随机抽查文件（如 `hdfs dfs -cat /user/test.txt`），确认数据完整性。
  5. 切换客户端：将应用程序的 `HADOOP_HOME` 指向 3.x 集群，测试读写功能，无异常后正式切换。
- **回滚预案**：升级过程中若出现故障，立即停止同步，切换客户端回 2.x 集群，待问题解决后重新升级。

#### 4.4 最新版本（3.3.x/3.4.x）特性预览
- **3.3.x（稳定版，如 3.3.6）**：
  - 增强 RBF 联邦：支持动态添加 NN 集群，无需重启 Router 节点。
  - 优化 EC 性能：减少校验块计算的 CPU 开销（提升 20% 重建速度）。
  - 安全增强：支持 Kerberos 1.20+，修复多个安全漏洞（如 CVE-2023-34469）。
- **3.4.x（实验版，如 3.4.0）**：
  - 引入 **Async NN**：支持异步处理元数据操作（如创建文件），提升 RPC QPS（预计提升 30%）。
  - 云原生优化：增强与 Kubernetes（K8s）的集成，支持 HDFS 容器化部署（用 StatefulSet 管理 DN 节点）。
- **生产建议**：优先选择 3.3.x 稳定版，3.4.x 待后续补丁版（如 3.4.2）发布后再考虑测试。


### 5. 生态与发展趋势：与外部世界结合
HDFS 并非孤立存在，而是大数据生态的“存储基石”，与计算引擎（Spark/Flink）、查询引擎（Hive/Presto）、NoSQL 数据库（HBase）深度集成；同时，随着云原生、存储计算分离的趋势，HDFS 也在不断适配新场景。

#### 5.1 与大数据生态组件的集成（生产核心场景）
HDFS 是生态组件的默认存储层，集成重点是 **优化读写接口、适配组件特性**，提升整体效率。

##### 5.1.1 与计算引擎集成（Spark/Flink）
- **Spark 与 HDFS 集成**：
  - 核心优化：
    1. **块大小适配**：Spark 读取 HDFS 文件时，默认 1 个块对应 1 个 Partition（Map 任务），生产中建议 HDFS 块大小设为 256MB，Spark Partition 大小也设为 256MB（`spark.sql.files.maxPartitionBytes=268435456`），减少任务调度开销。
    2. **并行度控制**：写入 HDFS 时用 `repartition`/`coalesce` 控制输出文件数（如 `df.coalesce(100).write.parquet("/output")`），避免小文件。
    3. **短-circuit 本地读**：启用 `dfs.client.read.shortcircuit=true`，Spark 任务在 DN 节点上运行时，直接读取本地磁盘块（不通过网络），提升读效率（需配置 `dfs.domain.socket.path` 本地 socket 路径）。
  - 常见问题：Spark 任务读写 HDFS 慢，排查是否启用本地读、是否存在大量小文件、网络带宽是否瓶颈。

- **Flink 与 HDFS 集成**：
  - 核心优化：
    1. **Checkpoint 存储**：Flink  checkpoint 存储到 HDFS 时，启用异步 checkpoint（`execution.checkpointing.async=true`），避免阻塞计算任务；同时设置 checkpoint 目录的副本数为 2（`hdfs dfs -setReplication /flink/checkpoints 2`），平衡可靠性与成本。
    2. **状态后端**：使用 `RocksDBStateBackend`，将状态快照存储到 HDFS，配置 `state.backend.rocksdb.localdir` 为本地 SSD 目录，提升状态读写速度。
    3. **文件输出**：用 `StreamingFileSink` 输出文件，设置滚动策略（`withRollingPolicy`），控制文件大小（如 128MB）和滚动时间（如 1 小时），避免小文件。

##### 5.1.2 与查询引擎集成（Hive/Presto）
- **Hive 与 HDFS 集成**：
  - 核心优化：
    1. **分区表存储**：Hive 分区表在 HDFS 上按分区目录存储（如 `/user/hive/warehouse/tbl/dt=20240501`），建议分区粒度适中（如按天分区，避免单目录文件数超 10 万）。
    2. **文件格式**：使用 ORC/Parquet 列式存储格式（比 TextFile 压缩率高 5-10 倍，查询速度快 3-5 倍），存储在 HDFS 时启用压缩（如 ORC 压缩 `orc.compress=SNAPPY`）。
    3. **元数据缓存**：启用 Hive Metastore 缓存（`hive.metastore.cache.size=10000`），减少 Hive 向 NN 查询 HDFS 元数据的次数。

- **Presto 与 HDFS 集成**：
  - 核心优化：
    1. **并行读**：Presto 读取 HDFS 文件时，设置 `hive.max-split-size=256MB`（与 HDFS 块大小一致），提升并行读效率。
    2. **缓存**：启用 Presto HDFS 缓存（`hive.hdfs.cache.enabled=true`），缓存频繁访问的小文件（如维度表），减少重复读取。

##### 5.1.3 与 NoSQL 数据库集成（HBase）
- **HBase 与 HDFS 集成**：
  - 核心关系：HBase 不直接存储数据，而是将数据按 Region 分裂为 HFile（大文件），存储在 HDFS 上，依赖 HDFS 的容错和存储能力。
  - 生产优化：
    1. **HFile 大小**：配置 HBase `hbase.hregion.max.filesize=10GB`（HFile 过大影响分裂，过小导致小文件），HDFS 块大小设为 256MB（HFile 由多个 HDFS 块组成）。
    2. **压缩**：启用 HFile 压缩（`hbase.hregion.compression=SNAPPY`），减少 HDFS 存储占用。
    3. **副本数**：HBase 目录（`/hbase`）的 HDFS 副本数设为 3（核心数据），HBase 归档目录（`/hbase/archive`）设为 2（非核心数据）。


#### 5.2 云原生趋势（HDFS 与云存储的融合）
随着云计算普及，HDFS 正从“本地集群存储”向“云原生存储”演进，核心趋势是 **与对象存储兼容、支持容器化部署、存储计算分离**。

##### 5.2.1 与对象存储兼容（S3/Azure Blob）
- **核心需求**：企业混合云部署（本地 HDFS + 云对象存储），需 HDFS 能读写云存储中的数据。
- **实现方案（Hadoop 3.x）**：
  - 配置 S3 兼容存储：
    ```xml
    <!-- core-site.xml 配置 -->
    <property>
      <name>fs.s3a.access.key</name>
      <value>AKIAXXX</value> <!-- S3 Access Key -->
    </property>
    <property>
      <name>fs.s3a.secret.key</name>
      <value>XXX</value> <!-- S3 Secret Key -->
    </property>
    <property>
      <name>fs.s3a.endpoint</name>
      <value>http://s3.example.com</value> <!-- S3  endpoint -->
    </property>
    <property>
      <name>fs.s3a.impl</name>
      <value>org.apache.hadoop.fs.s3a.S3AFileSystem</value> <!-- S3 实现类 -->
    </property>
    ```
  - 读写 S3 数据：
    ```bash
    # 从 S3 读取文件到本地
    hdfs dfs -copyToLocal s3a://bucket/test.txt /local/path/
    # 从本地写入文件到 S3
    hdfs dfs -copyFromLocal /local/test.txt s3a://bucket/
    ```
- **生产注意事项**：云存储读写速度受网络带宽限制，建议将计算任务部署在云厂商的 ECS 实例中（如 AWS EC2），减少跨区域网络延迟。

##### 5.2.2 HDFS 容器化部署（K8s）
- **核心需求**：容器化部署可快速扩缩容、简化运维，适合云原生环境。
- **实现方案**：
  - 用 StatefulSet 部署 DN（需持久化存储，如 PV/PVC，对应云厂商的 EBS/GFS），Deployment 部署 NN/JN/ZKFC（无状态组件）。
  - 核心配置（StatefulSet 示例）：
    ```yaml
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: hdfs-datanode
    spec:
      serviceName: hdfs-dn
      replicas: 3
      selector:
        matchLabels:
          app: datanode
      template:
        metadata:
          labels:
            app: datanode
        spec:
          containers:
          - name: datanode
            image: apache/hadoop:3.3.6
            command: ["hdfs", "datanode"]
            volumeMounts:
            - name: dn-data
              mountPath: /data/dn
      volumeClaimTemplates:
      - metadata:
          name: dn-data
        spec:
          accessModes: [ "ReadWriteOnce" ]
          resources:
            requests:
              storage: 100Gi
    ```
- **挑战与解决**：
  - 持久化存储：DN 数据需存储在 PV 中，避免容器重启后数据丢失。
  - 网络：K8s 内部用 Service 暴露 NN/JN 端口，外部通过 Ingress 访问 Web UI。

##### 5.2.3 存储计算分离
- **核心理念**：将 HDFS 存储节点与 Spark/Flink 计算节点分开部署，计算节点可弹性扩缩容（无需绑定存储），存储节点长期稳定运行。
- **实现方案**：
  1. 存储集群：独立部署 HDFS 集群（NN+DN+JN），专注数据存储。
  2. 计算集群：部署 Spark/Flink 集群，通过 YARN/K8s 弹性扩缩容，计算任务远程读取 HDFS 数据（需保证网络互通）。
- **生产优势**：
  - 成本优化：计算节点在业务低峰期可缩容，减少资源浪费。
  - 稳定性：存储集群不依赖计算集群，避免计算任务抢占存储节点资源。


#### 5.3 其他发展趋势（绿色计算、智能存储）
##### 5.3.1 绿色计算（节能优化）
- **核心方向**：降低 HDFS 集群能耗，适合大型数据中心（如阿里、腾讯的超大规模集群）。
- **优化措施**：
  - DN 节点动态节能：在夜间低峰期，将空闲 DN 节点设为“休眠模式”（关闭部分磁盘，降低 CPU 频率），高峰期唤醒。
  - 智能调度：NN 优先将块分配到低能耗节点（如采用 ARM 架构的服务器，比 x86 节能 30%）。

##### 5.3.2 智能存储（AI 辅助优化）
- **核心方向**：用 AI 算法预测数据访问频率、自动调整存储策略（热/温/冷）。
- **应用场景**：
  - 访问预测：通过 LSTM 模型预测未来 7 天的数据访问频率，将高频访问数据自动迁移到 SSD（热存储），低频数据迁移到 HDD（冷存储）。
  - 故障预测：用机器学习模型分析 DN 磁盘的 IO 延迟、坏道数，提前预测磁盘故障，触发数据迁移（避免块丢失）。


### 6. 最佳实践 / 场景化思维：在不同情境中灵活运用
HDFS 需结合具体业务场景（如日志存储、大数据计算、冷数据归档）进行定制化配置，本节聚焦 5 个生产高频场景，提供“问题-方案-配置-验证”全流程实践，覆盖面试中“结合场景谈 HDFS 优化”的高频提问。

#### 6.1 场景 1：日志存储（Flume 采集 + HDFS 存储）
- **业务特点**：
  - 数据量：每日 TB 级（如 APP 日志、服务器日志）。
  - 写入模式：实时持续写入（Flume 采集），文件小（单日志文件 <100MB）。
  - 读取模式：离线分析（如 Spark 统计 PV/UV），按时间分区读取（如按天/小时）。
- **核心问题**：小文件泛滥（导致 NN 内存压力大）、写入速度慢（Flume 单线程写入）。

##### 6.1.1 解决方案
1. **Flume 源头合并小文件**：配置滚动策略，控制 HDFS 输出文件大小。
2. **HDFS 存储优化**：按时间分区存储，非核心日志启用 EC 降低成本。
3. **读取优化**：Spark 读取时合并小文件，提升分析效率。

##### 6.1.2 生产配置
- **Flume 配置（`flume-conf.properties`）**：
  ```properties
  # 1. 数据源（Taildir 监控日志文件）
  a1.sources.r1.type = TAILDIR
  a1.sources.r1.filegroups = f1
  a1.sources.r1.filegroups.f1 = /var/log/app/*.log
  a1.sources.r1.positionFile = /var/flume/taildir_position.json
  
  # 2. 拦截器（添加时间戳，用于 HDFS 分区）
  a1.sources.r1.interceptors = i1
  a1.sources.r1.interceptors.i1.type = timestamp
  a1.sources.r1.interceptors.i1.headerName = timestamp
  
  # 3. 下沉到 HDFS
  a1.sinks.k1.type = hdfs
  a1.sinks.k1.hdfs.path = hdfs://nn1:9000/logs/app/%Y%m%d/%H/  # 按天/小时分区
  a1.sinks.k1.hdfs.filePrefix = app-log-
  a1.sinks.k1.hdfs.fileSuffix = .log
  a1.sinks.k1.hdfs.rollSize = 134217728  # 128MB 滚动（控制文件大小）
  a1.sinks.k1.hdfs.rollInterval = 3600   # 1 小时滚动（取大小/时间最小值）
  a1.sinks.k1.hdfs.rollCount = 0         # 禁用行数滚动
  a1.sinks.k1.hdfs.batchSize = 1000      # 批量写入（提升效率）
  a1.sinks.k1.hdfs.fileType = DataStream # 不压缩（后续 Spark 处理时压缩）
  
  # 4. 通道（内存通道，提升吞吐量）
  a1.channels.c1.type = memory
  a1.channels.c1.capacity = 100000
  a1.channels.c1.transactionCapacity = 10000
  
  # 5. 绑定 source-channel-sink
  a1.sources.r1.channels = c1
  a1.sinks.k1.channel = c1
  ```
- **HDFS 配置（`hdfs-site.xml`）**：
  ```xml
  <!-- 1. 日志目录副本数设为 2（非核心数据，降低成本） -->
  <property>
    <name>dfs.replication</name>
    <value>2</value>
  </property>
  <!-- 2. 30 天前的日志启用 EC（RS-6-3） -->
  <property>
    <name>dfs.storage.policy.enabled</name>
    <value>true</value>
  </property>
  ```
- **Spark 读取配置（分析日志时）**：
  ```scala
  // 读取 20240501 当天的日志，合并小文件（设为 256MB 分区）
  val logs = spark.read.text("hdfs://nn1:9000/logs/app/20240501/*")
    .repartition(spark.sparkContext.defaultParallelism * 2) // 并行度设为 CPU 核数的 2 倍
  // 写入 ORC 格式（压缩存储，便于后续查询）
  logs.write.mode("overwrite").orc("hdfs://nn1:9000/analysis/app-logs-20240501")
  ```

##### 6.1.3 验证与监控
- **验证文件大小**：通过`hdfs dfs -du -h /logs/app/20240501/00/`命令检查文件大小，确保单文件接近128MB（Flume配置的滚动阈值）。若文件普遍偏小（如<50MB），需调整Flume的`rollSize`和`rollInterval`参数，避免小文件泛滥。
- **监控小文件数**：通过Prometheus监控`hdfs_files_total{path=~"/logs/app/.*"}`指标，设置每日新增文件数阈值（如<1万）。若超标，触发告警并排查原因（如Flume滚动策略失效、日志源产生碎片文件）。
- **监控写入速度**：Flume侧监控`flume.sink.hdfs.writeRate`（每秒写入HDFS的字节数）和`flume.channel.capacity.used.percent`（通道使用率）。正常情况下，写入速率应稳定在集群网络带宽的50%-70%（如千兆网卡约50-70MB/s），通道使用率<80%。若写入速率骤降或通道使用率持续攀升，需检查HDFS DN磁盘IO、网络链路是否拥堵。
- **数据完整性校验**：定期执行`hdfs dfs -checksum /logs/app/20240501/00/app-log-xxx.log`获取文件校验和，与源日志文件的校验和对比，确保传输过程无数据损坏。每月随机抽查10%的文件，重点验证峰值时段（如秒杀活动期间）的日志完整性。
- **存储策略验证**：通过`hdfs storagepolicies -getPolicy -path /logs/app/20240401`确认历史日志已应用EC策略（如RS-6-3），降低存储成本。同时监控`hdfs_ec_blocks_total`指标，确保EC块占比与冷数据量匹配。

##### 6.1.3 验证与监控
针对日志存储场景，需通过**定期验证**确保数据质量与配置有效性，通过**实时监控**及时发现异常（如小文件反弹、写入延迟），避免影响后续分析。

- 6.1.3.1 验证措施（每日/每周执行）  
1. **文件大小与数量验证**  
   - 执行命令检查单个日志文件大小是否符合预期（128MB左右）：  
     ```bash
     # 查看某小时分区的文件大小
     hdfs dfs -du -h /logs/app/$(date +%Y%m%d)/$(date +%H)/
     # 示例输出：128.0 M  /logs/app/20240501/08/app-log-12345.log
     ```
   - 统计每日新增文件总数，确保不超过阈值（如1万）：  
     ```bash
     hdfs dfs -count /logs/app/$(date +%Y%m%d)
     # 输出格式：目录数  文件数  总大小  路径，重点关注文件数
     ```

2. **数据完整性验证**  
   - 随机抽取本地日志与HDFS存储日志，对比校验和（确保传输无损坏）：  
     ```bash
     # 本地日志校验和
     md5sum /var/log/app/app.log.20240501 > local.md5
     # HDFS日志下载并计算校验和
     hdfs dfs -get /logs/app/20240501/00/app-log-12345.log /tmp/
     md5sum /tmp/app-log-12345.log > hdfs.md5
     # 对比校验和
     diff local.md5 hdfs.md5
     ```
   - 若校验和不一致，检查Flume通道配置（如是否启用事务，`transactionCapacity`是否合理）。

3. **存储策略生效验证**  
   - 确认30天前的日志已自动应用EC策略：  
     ```bash
     hdfs ec -getPolicy -path /logs/app/$(date -d "30 days ago" +%Y%m%d)
     # 预期输出：Policy Name: RS-6-3-1024k
     ```


- 监控指标与告警（实时/准实时）  
1. **核心监控指标**  
   | 监控对象 | 关键指标 | 阈值 | 说明 |  
   |----------|----------|------|------|  
   | Flume | `sink.hdfs.success`（成功写入HDFS的事件数） | 5分钟内成功率<99% | 写入失败率过高，可能是HDFS繁忙或网络故障 |  
   | Flume | `channel.capacity.used`（通道使用率） | >80% | 通道满导致数据积压，需调大`capacity` |  
   | HDFS | `hdfs_files_total{path=~"/logs/app/.*"}`（日志目录文件总数） | 单日新增>1万 | 小文件泛滥风险，需检查Flume滚动配置 |  
   | HDFS | `datanode_disk_used_percent{path=~"/data.*"}`（DN磁盘使用率） | >85% | 磁盘空间不足，需扩容或清理旧日志 |  
   | 网络 | `node_network_transmit_bytes{device=~"eth0"}`（节点出网带宽） | >800Mbps（千兆网卡） | 网络带宽瓶颈，影响日志写入速度 |  

2. **告警配置（Prometheus Alertmanager）**  
   ```yaml
   groups:
   - name: hdfs-log-alerts
     rules:
     - alert: HdfsLogFileExceed
       expr: increase(hdfs_files_total{path=~"/logs/app/.*"}[1d]) > 10000
       for: 5m
       labels:
         severity: critical
       annotations:
         summary: "日志目录文件数超标"
         description: "过去24小时新增日志文件数超过1万，可能导致NN内存压力增大"
   
     - alert: FlumeHdfsWriteFail
       expr: rate(flume_sink_hdfs_failed[5m]) / rate(flume_sink_hdfs_total[5m]) > 0.01
       for: 3m
       labels:
         severity: warning
       annotations:
         summary: "Flume写入HDFS失败率过高"
         description: "过去5分钟Flume写入HDFS失败率超过1%，请检查HDFS状态"
   ```

3. **日志监控（ELK）**  
   - 收集Flume日志中的`ERROR`级别信息（如`HDFS IO Exception`）、HDFS NN日志中的`BlockMissingException`，设置关键词告警，实时定位异常原因（如HDFS DN宕机导致写入失败）。  


- 6.1.3.3 问题排查与优化（常见场景）  
  - **场景1：小文件数突然增多**  
    排查：检查Flume `rollSize`是否被篡改（如误设为1MB），或日志源产生大量碎片日志（如应用频繁重启生成小文件）。  
    解决：恢复Flume滚动配置，源头合并小日志（如应用侧按100MB滚动生成日志文件）。  
  
  - **场景2：Flume写入延迟高**  
    排查：用`iostat -x 1`检查DN磁盘IO使用率（`%util`是否接近100%），用`iftop`检查网络带宽是否饱和。  
    解决：若磁盘IO高，调整DN磁盘调度算法为`mq-deadline`；若网络饱和，升级机架交换机带宽（如从千兆到万兆）。  


#### 6.2 场景2：大数据计算存储（Spark/Flink计算结果存储）
- **业务特点**：  
  - 数据量：单次计算输出数十GB至TB级（如用户画像、推荐模型特征）。  
  - 写入模式：批量写入（计算任务结束时一次性输出），文件较大（单文件256MB+）。  
  - 读取模式：高频读取（如后续模型训练、报表生成），需低延迟。  

- **核心问题**：计算任务输出文件分布不均（部分文件过大/过小）、读取时网络开销高、存储成本与读取性能平衡。  


##### 6.2.1 解决方案
1. **计算侧控制输出文件粒度**：通过`repartition`调整Spark/Flink并行度，确保输出文件大小均匀（256-512MB）。  
2. **HDFS存储优化**：热数据（30天内）用3副本+SSD存储，提升读取速度；温数据（30-90天）用2副本+HDD，降低成本。  
3. **读取加速**：启用客户端本地读（Short-Circuit Read）和数据预读取，减少网络延迟。  


##### 6.2.2 生产配置
- **Spark输出配置**：  
  ```scala
  // 假设总数据量为100GB，按256MB/文件计算，需400个分区（100GB/256MB≈400）
  val featureData = spark.read.parquet("/user/model/rawdata")
  //  repartition按哈希分区，确保数据均匀分布
  featureData.repartition(400)
    .write
    .mode("overwrite")
    .option("compression", "snappy") // 启用Snappy压缩（平衡压缩率与速度）
    .parquet("/user/model/features/20240501")
  ```

- **HDFS存储策略配置**：  
  ```bash
  # 为热数据目录设置HOT策略（SSD+3副本）
  hdfs storagepolicies -setStoragePolicy /user/model/features HOT
  # 为90天前的温数据设置WARM策略（HDD+2副本）
  hdfs storagepolicies -setStoragePolicy /user/model/features/$(date -d "90 days ago" +%Y%m%d) WARM
  ```

- **客户端读取优化（`core-site.xml`）**：  
  ```xml
  <!-- 启用本地读（需配置socket路径） -->
  <property>
    <name>dfs.client.read.shortcircuit</name>
    <value>true</value>
  </property>
  <property>
    <name>dfs.domain.socket.path</name>
    <value>/var/run/hadoop-hdfs/dn._PORT</value> <!-- DN本地socket路径 -->
  </property>
  <!-- 预读取大小（256MB） -->
  <property>
    <name>dfs.client.read.prefetch.size</name>
    <value>268435456</value>
  </property>
  ```


##### 6.2.3 验证与监控
1. **文件均匀性验证**：  
   ```bash
   # 检查输出目录文件大小分布
   hdfs dfs -du -h /user/model/features/20240501 | sort -h
   # 预期结果：所有文件大小在250-270MB之间，无明显偏差
   ```

2. **存储策略验证**：  
   ```bash
   # 检查热数据目录存储策略
   hdfs storagepolicies -getStoragePolicy /user/model/features/20240501
   # 预期输出：Policy Name: HOT
   ```

3. **核心监控指标**：  
   - `spark_job_output_file_count`（Spark输出文件数）：确保与预期分区数一致，避免数据倾斜。  
   - `hdfs_block_local_read_ratio`（本地读比例）：应≥70%（计算任务优先调度在数据所在节点）。  
   - `dfs_client_read_latency`（读取延迟）：P95延迟应≤50ms（SSD存储场景）。  


#### 6.3 场景3：冷数据归档（历史数据长期存储）
- **业务特点**：  
  - 数据量：PB级（如3年前的用户行为日志、过期订单数据）。  
  - 访问频率：极低（每年≤1次），主要用于合规审计或偶尔追溯。  
  - 核心需求：极致降低存储成本，保证数据不丢失（保存周期≥5年）。  

- **核心问题**：存储成本高（3副本开销大）、数据长期存储可能出现静默损坏（磁盘比特翻转）。  


##### 6.3.1 解决方案
1. **存储策略**：采用EC纠删码（RS-6-3）替代副本，存储开销从300%降至150%；搭配低成本SATA HDD（比SSD便宜60%）。  
2. **数据校验**：启用DN块扫描加速（缩短扫描周期至1周），定期检测并修复损坏块。  
3. **访问控制**：通过Ranger设置权限，仅允许审计账号读取，防止误删。  


##### 6.3.2 生产配置
- **EC策略配置**：  
  ```bash
  # 启用RS-6-3策略（6数据块+3校验块）
  hdfs ec -enablePolicy -policy RS-6-3-1024k
  # 为冷数据目录应用EC策略
  hdfs ec -setPolicy -path /archive/userlogs -policy RS-6-3-1024k
  ```

- **DN块扫描优化（`hdfs-site.xml`）**：  
  ```xml
  <!-- 缩短块扫描周期至1周（168小时） -->
  <property>
    <name>dfs.datanode.scan.period.hours</name>
    <value>168</value>
  </property>
  <!-- 增加扫描线程数至4（加速扫描） -->
  <property>
    <name>dfs.datanode.scan.threads</name>
    <value>4</value>
  </property>
  ```

- **Ranger权限配置**：  
  - 仅允许`audit`角色对`/archive/userlogs`有`read`权限，其他角色无权限。  
  - 禁用`delete`操作（`hdfs dfs -rm`对该目录无效）。  


##### 6.3.3 验证与监控
1. **EC策略生效验证**：  
   ```bash
   # 查看冷数据目录的块存储方式
   hdfs fsck /archive/userlogs -files -blocks -locations
   # 预期输出：每个块包含6个数据块和3个校验块，分布在不同DN
   ```

2. **数据完整性验证（每年1次）**：  
   - 随机抽取100个冷文件，下载后与归档时的校验和对比，确保无损坏。  

3. **核心监控指标**：  
   - `hdfs_ec_blocks_total`（EC块总数）：与冷数据量匹配，确保策略正确应用。  
   - `datanode_scan_corrupt_blocks`（扫描发现的损坏块数）：应保持为0，若>0需立即排查磁盘。  


#### 6.4 场景4：HBase底层存储（实时数据库数据持久化）
- **业务特点**：  
  - 数据量：TB至PB级（如用户实时行为、设备状态数据）。  
  - 读写模式：随机读写频繁（HBase实时写入，查询时随机读取）。  
  - 存储依赖：HBase将数据压缩为HFile（大文件）存储在HDFS，依赖HDFS的高吞吐和容错性。  

- **核心问题**：HFile分裂导致小文件、随机读写放大磁盘IO、HBase RegionServer与HDFS DN资源竞争。  


##### 6.4.1 解决方案
1. **HFile大小控制**：调整HBase参数，避免HFile过小（分裂频繁）或过大（分裂耗时）。  
2. **存储与计算资源隔离**：HBase RegionServer与HDFS DN部署在不同节点，避免CPU/内存竞争。  
3. **HDFS优化**：为HBase目录设置3副本（核心数据），启用短-circuit本地读提升随机读性能。  


##### 6.4.2 生产配置
- **HBase配置（`hbase-site.xml`）**：  
  ```xml
  <!-- HFile最大大小（10GB，避免过大） -->
  <property>
    <name>hbase.hregion.max.filesize</name>
    <value>10737418240</value>
  </property>
  <!-- HFile最小大小（1GB，避免过小） -->
  <property>
    <name>hbase.hregion.memstore.flush.size</name>
    <value>1073741824</value>
  </property>
  <!-- 启用Snappy压缩HFile -->
  <property>
    <name>hbase.hregion.compression</name>
    <value>SNAPPY</value>
  </property>
  ```

- **HDFS配置**：  
  ```bash
  # HBase根目录设为3副本
  hdfs dfs -setReplication 3 /hbase
  # 启用短-circuit本地读（同6.2.2配置）
  ```

- **资源隔离**：  
  - 集群节点分为“存储节点”（仅部署HDFS DN）和“计算节点”（仅部署HBase RegionServer），通过YARN标签调度实现隔离。  


##### 6.4.3 验证与监控
1. **HFile大小验证**：  
   ```bash
   # 查看HBase表的HFile大小
   hdfs dfs -du -h /hbase/data/default/usertable/*/*/
   # 预期结果：HFile大小在1-10GB之间
   ```

2. **核心监控指标**：  
   - `hbase_regionserver_storefile_count`（每个Region的HFile数）：应≤5（过多需合并）。  
   - `hdfs_datanode_volume_failures`（DN磁盘故障数）：应=0（磁盘故障影响HBase数据可靠性）。  
   - `hbase_regionserver_get_latency`（HBase读取延迟）：P95延迟应≤10ms（依赖HDFS本地读性能）。  


#### 6.5 场景5：多租户共享集群（部门/业务线共用HDFS）
- **业务特点**：  
  - 租户类型：多个部门（如电商、支付、风控）共用HDFS集群，数据量与读写模式差异大。  
  - 核心需求：资源隔离（避免某租户占用过多带宽/IO）、权限管控（数据不可跨租户访问）、计费计量（按存储/IO量收费）。  

- **核心问题**：资源争抢（如某租户批量写入导致其他租户读延迟）、权限泄露、计量不准确。  


##### 6.5.1 解决方案
1. **资源隔离**：通过HDFS配额（空间/文件数）和YARN队列限制租户资源；启用HDFS带宽控制（每租户读写带宽上限）。  
2. **权限管控**：基于Ranger实现租户级目录权限（如`/user/tenant1`仅`tenant1`可读写），禁用跨目录访问。  
3. **计量与计费**：通过HDFS审计日志统计各租户的存储量、IO次数，结合成本模型计费。  


##### 6.5.2 生产配置
- **HDFS配额配置**：  
  ```bash
  # 为tenant1设置空间配额100TB、文件数配额100万
  hdfs dfsadmin -setSpaceQuota 100t /user/tenant1
  hdfs dfsadmin -setQuota 1000000 /user/tenant1
  # 查看配额使用情况
  hdfs dfs -count -q /user/tenant1
  ```

- **带宽控制（`hdfs-site.xml`）**：  
  ```xml
  <!-- 启用带宽控制器 -->
  <property>
    <name>dfs.qos.enabled</name>
    <value>true</value>
  </property>
  <!-- 为tenant1设置写入带宽上限100MB/s -->
  <property>
    <name>dfs.qos.tenant.tenant1.write.bandwidth</name>
    <value>104857600</value> <!-- 100MB/s = 100*1024*1024 B/s -->
  </property>
  ```

- **Ranger权限配置**：  
  - 为`/user/tenant1`创建策略：仅`tenant1`用户组有`read`/`write`权限，其他用户组无权限。  
  - 禁用`chmod`/`chown`操作（防止权限篡改）。  


##### 6.5.3 验证与监控
1. **配额与权限验证**：  
   ```bash
   # 验证配额：尝试上传超过配额的文件，应失败
   hdfs dfs -put 101TB_file /user/tenant1
   # 预期错误：Quota exceeded
   
   # 验证权限：用tenant2用户尝试访问tenant1目录，应失败
   sudo -u tenant2 hdfs dfs -ls /user/tenant1
   # 预期错误：Permission denied
   ```

2. **核心监控指标**：  
   - `hdfs_quota_space_used{tenant=tenant1}`（租户空间使用率）：超过80%触发扩容提醒。  
   - `hdfs_tenant_write_bandwidth{tenant=tenant1}`（租户写入带宽）：确保不超过配置上限。  
   - `ranger_permission_denied_count`（权限拒绝次数）：突增可能是恶意访问，需告警。  
