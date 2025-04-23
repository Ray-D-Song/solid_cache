# Solid Cache 学习笔记

此文件用于记录学习 Solid Cache 源代码过程中的笔记和总结。 

## Solid Cache 架构总结

Solid Cache 通过将缓存数据存储在数据库 (通常是 SSD 上的表) 中来实现持久化缓存，旨在提供比内存缓存 (如 Redis, Memcached) 更大的容量和更低的成本，同时保持可接受的性能。其核心架构围绕 `ActiveSupport::Cache::Store` 接口构建，并利用 Active Record 进行数据库交互。

**核心组件:**

1.  **`SolidCache::Store` (lib/solid_cache/store.rb)**
    *   缓存实现的主入口，继承自 `ActiveSupport::Cache::Store`。
    *   通过 `include` 多个功能模块 (Api, Connections, Entries, Execution, Expiry, Failsafe, Stats) 来组织代码。
    *   `prepend ActiveSupport::Cache::Strategy::LocalCache` 以支持可选的内存本地缓存层。
    *   负责协调各个模块完成缓存操作。

2.  **`Store` 模块 (lib/solid_cache/store/)**
    *   **`Api`**: 实现标准的 Rails Cache API 方法 (`read`, `write`, `fetch`, `delete`, `increment`, `decrement`, `read_multi`, `write_multi`, `clear`)。处理键的规范化 (`normalize_key`) 和截断 (`truncate_key`)，防止键过长。
    *   **`Entries`**: 作为 `Store` 和 `Entry` 模型之间的桥梁。将 API 调用转换为对 `Entry` 模型的具体数据库操作 (`entry_read`, `entry_write`, `entry_delete`, `entry_clear`, `entry_lock_and_write` 等)。
    *   **`Connections`**: 管理数据库连接和分片。
        *   读取分片配置 (`shard_options`)。
        *   使用 `SolidCache::Connections` 工厂类创建连接策略实例 (`Sharded`, `Single`, `Unmanaged`)。
        *   提供 `with_connection_for(key)`, `with_connection(name)`, `with_each_connection` 等方法，确保操作在正确的数据库分片上执行。
        *   提供 `reading_key`, `reading_keys`, `writing_key`, `writing_keys`, `writing_all` 等方法，将 `Entries` 的操作包装在正确的连接和 `failsafe` 逻辑中。
    *   **`Execution`**: 控制操作的执行方式。
        *   包含一个线程池 (`Concurrent::FixedThreadPool`) 用于异步执行任务 (如过期清理)。
        *   提供 `async` 方法将块放入后台执行，并使用 `SolidCache.executor` (通常是 Rails 应用的 executor) 包装以确保 Rails 环境。
        *   提供 `execute` 方法根据 `async` 参数决定同步或异步执行。
        *   允许通过配置禁用 Active Record 的 instrumentation (`disable_instrumentation`)。
    *   **`Expiry`**: 触发缓存过期逻辑。
        *   根据配置 (`expiry_method`)，通过 Store 内部线程池 (`:thread`) 或 Active Job (`:job`) 异步安排 `Entry.expire` 任务。
        *   根据写入频率 (`track_writes`) 和 `EXPIRY_MULTIPLIER` 决定触发过期任务的数量，以维持缓存大小。
    *   **`Failsafe`**: 提供错误处理。
        *   定义瞬时数据库错误列表 (`TRANSIENT_ACTIVE_RECORD_ERRORS`)。
        *   提供 `failsafe` 方法包裹数据库操作，捕获瞬时错误，调用错误处理器 (`error_handler`)，并返回默认值，避免缓存操作失败影响应用。
    *   **`Stats`**: 提供缓存统计信息。
        *   `stats` 方法返回全局和每个分片的统计数据，如连接数、条目数、最旧条目年龄等。

3.  **`SolidCache::Entry` (app/models/solid_cache/entry.rb)**
    *   核心 Active Record 模型，负责将缓存数据 (`key`, `value`) 持久化到数据库表 (`solid_cache_entries`)。
    *   继承自 `SolidCache::Record`。
    *   **键哈希**: 使用 `key_hash` 字段 (SHA256 哈希的 64 位整数) 作为主索引，用于高效查询和分片。
    *   **数据库操作**: 提供类方法 (`write`, `read`, `delete_by_key`, `clear_truncate`, `clear_delete`, `lock_and_write`, `write_multi`, `read_multi`) 执行底层的 SQL 操作。
    *   **性能优化**: 使用 `upsert_all` 进行批量写入/更新；批量处理读写 (`MULTI_BATCH_SIZE`)；缓存 SQL 查询模板 (`select_sql`)；禁用查询缓存 (`without_query_cache`)。
    *   **Concerns**:
        *   `Encryption`: 根据配置使用 Active Record 加密功能加密 `value` 字段。
        *   `Expiration`: 实现 `expire` 方法，根据最大年龄、条目数、大小限制查找并删除过期候选条目，使用随机采样减少并发冲突。
        *   `Size`: 提供与 `byte_size` 字段相关的查询作用域，并实现 `estimated_size` 方法估算缓存总大小。

4.  **`SolidCache::Record` (app/models/solid_cache/record.rb)**
    *   `Entry` 的 Active Record 基类。
    *   配置数据库连接 (`connects_to`)，读取全局配置。
    *   提供分片切换的核心方法 (`with_shard`, `each_shard`)，利用 Active Record 的 `connected_to`。
    *   提供禁用 instrumentation 的方法 (`disable_instrumentation`)。

5.  **`SolidCache::Connections` (lib/solid_cache/connections.rb & lib/solid_cache/connections/)**
    *   **`from_config` 工厂**: 根据配置决定使用 `Sharded`, `Single`, 还是 `Unmanaged` 策略。
    *   **`Sharded`**: 处理多个分片。使用 `MaglevHash` (一致性哈希) 将 key 映射到分片名称 (`shard_for`)；使用 `Record.with_shard` 切换连接；提供 `assign` 方法将 key 按分片分组。
    *   **`Single`**: 处理单个指定分片，所有操作都路由到该分片。
    *   **`Unmanaged`**: 不进行连接管理，所有操作在当前默认连接上执行。

6.  **`SolidCache::MaglevHash` (lib/solid_cache/maglev_hash.rb)**
    *   实现了 Google Maglev 一致性哈希算法。
    *   通过构建查找表 (lookup table) 和节点偏好列表 (preference list)，将 key 稳定地映射到节点 (分片)，即使节点数量变化也能最小化 key 的重新分布。

7.  **`SolidCache::Configuration` (lib/solid_cache/configuration.rb)**
    *   存储所有配置项。
    *   处理不同的数据库连接配置方式 (`:database`, `:databases`, `:connects_to`)。
    *   提供默认的加密配置。

8.  **`SolidCache::Engine` (lib/solid_cache/engine.rb)**
    *   作为 Rails Engine 集成到 Rails 应用。
    *   负责在初始化过程中加载配置、设置 `SolidCache.configuration` 和 `SolidCache.executor`。
    *   执行初始化后的检查和设置。

**数据流 (简化写操作):**

1.  应用调用 `Rails.cache.write(key, value)`。
2.  `SolidCache::Store#write` (继承自 `ActiveSupport::Cache::Store`) 被调用。
3.  `Api#write_entry` 被调用。
4.  `Api#normalize_key` 处理键。
5.  `Api#serialize_entry` 序列化值。
6.  `Entries#entry_write` 被调用。
7.  `Connections#writing_key` (包装器) 被调用。
8.  `Connections` 策略 (如 `Sharded`) 的 `with_connection_for(key)` 被调用，确定目标分片。
9.  `Record.with_shard` 切换到目标分片连接。
10. `Failsafe#failsafe` 包裹实际数据库操作。
11. `Entries` 模块内部调用 `Entry.write(key, payload)`。
12. `Entry.write` 调用 `Entry.write_multi`。
13. `Entry.write_multi` 计算 `key_hash` 和 `byte_size`，调用 `upsert_all` 将数据写入数据库表。
14. `Entries#track_writes` 被调用。
15. `Expiry#track_writes` 被调用，根据写入次数决定是否触发 `Expiry#expire_later`。
16. `Expiry#expire_later` 异步安排 `Entry.expire` 任务 (通过线程池或 Active Job)。

这种模块化的设计使得 Solid Cache 的各个功能清晰分离，易于理解和维护。它巧妙地结合了 Active Record 的功能 (模型、数据库交互、分片、加密) 和 Active Support 的工具 (缓存 API、Notifications、Executor) 来实现一个基于数据库的缓存系统。 