# frozen_string_literal: true

module SolidCache
  # Entry 模型是 Solid Cache 的核心数据模型，继承自 Active Record。
  # 它负责将缓存键值对持久化到数据库表中。
  class Entry < Record
    # 引入加密、过期和大小计算相关逻辑的模块。
    include Encryption, Expiration, Size

    # 估算的每行额外开销（字节），包括固定大小列、索引、开销和碎片空间。
    # 这个值基于 SQLite, MySQL, PostgreSQL 的实验结果。
    ESTIMATED_ROW_OVERHEAD = 140

    # 假设使用 MessagePack 序列化时，估算的加密额外开销。
    ESTIMATED_ENCRYPTION_OVERHEAD = 170

    # key_hash (SHA256 哈希的有符号 64 位整数表示) 的取值范围。
    KEY_HASH_ID_RANGE = -(2**63)..(2**63 - 1)

    # 批量读写操作的分批大小。
    MULTI_BATCH_SIZE = 1000

    class << self
      # 写入单个键值对。
      # 内部调用 write_multi。
      def write(key, value)
        write_multi([ { key: key, value: value } ])
      end

      # 批量写入键值对。
      # 使用 upsert_all 实现高效的插入或更新。
      def write_multi(payloads)
        # 禁用查询缓存，确保直接操作数据库。
        without_query_cache do
          # 将数据分批处理。
          payloads.each_slice(MULTI_BATCH_SIZE).each do |payload_batch|
            upsert_all \
              # 为每条记录添加 key_hash 和 byte_size。
              add_key_hash_and_byte_size(payload_batch),
              # 根据 key_hash 进行唯一性判断。
              # 如果数据库支持 INSERT ... ON CONFLICT，则使用 key_hash 作为冲突目标，否则依赖数据库行为。
              unique_by: upsert_unique_by,
              # 如果记录已存在 (基于 unique_by)，则更新指定字段。
              on_duplicate: :update,
              update_only: [ :key, :value, :byte_size ]
          end
        end
      end

      # 读取单个键对应的值。
      # 内部调用 read_multi。
      def read(key)
        read_multi([key])[key]
      end

      # 批量读取多个键对应的值。
      def read_multi(keys)
        # 禁用查询缓存。
        without_query_cache do
          {}.tap do |results|
            # 将键分批处理。
            keys.each_slice(MULTI_BATCH_SIZE).each do |keys_batch|
              # 构建并执行 SQL 查询。
              # 使用 select_sql 方法获取缓存的 SQL 模板，并传入 key_hash 作为绑定参数。
              query = Arel.sql(select_sql(keys_batch), *key_hashes_for(keys_batch))

              # 执行查询并将结果转换为 { key => value } 的哈希。
              results.merge!(connection.select_all(query, "SolidCache::Entry Load").cast_values(attribute_types).to_h)
            end
          end
        end
      end

      # 根据键批量删除缓存条目。
      def delete_by_key(*keys)
        # 禁用查询缓存。
        without_query_cache do
          # 根据 key_hash 进行删除。
          where(key_hash: key_hashes_for(keys)).delete_all
        end
      end

      # 使用 TRUNCATE TABLE 清空缓存表。
      def clear_truncate
        connection.truncate(table_name)
      end

      # 使用 DELETE FROM 清空缓存表。
      # 采用分批删除以避免锁表时间过长。
      def clear_delete
        # 禁用查询缓存。
        without_query_cache do
          in_batches.delete_all
        end
      end

      # 获取行锁并执行写入操作，用于原子更新。
      def lock_and_write(key, &block)
        # 在事务中执行。
        transaction do
          # 禁用查询缓存。
          without_query_cache do
            # 使用 SELECT ... FOR UPDATE 获取行锁，并读取 key 和 value。
            result = lock.where(key_hash: key_hash_for(key)).pick(:key, :value)
            # 调用传入的块，计算新值。如果读取到的 key 与传入的 key 匹配，则将旧值传给块。
            new_value = block.call(result&.first == key ? result[1] : nil)
            # 如果块返回了新值，则写入数据库。
            write(key, new_value) if new_value
            # 返回新值。
            new_value
          end
        end
      end

      # 获取表中 ID 的范围大小 (估算)。
      def id_range
        # 禁用查询缓存。
        without_query_cache do
          pick(Arel.sql("max(id) - min(id) + 1")) || 0
        end
      end

      private
        # 为写入的数据添加 key_hash 和估算的 byte_size。
        def add_key_hash_and_byte_size(payloads)
          payloads.map do |payload|
            payload.dup.tap do |p|
              p[:key_hash] = key_hash_for(p[:key])
              p[:byte_size] = byte_size_for(p)
            end
          end
        end

        # 根据数据库是否支持 INSERT ... ON CONFLICT 来决定 upsert 的唯一性约束字段。
        def upsert_unique_by
          connection.supports_insert_conflict_target? ? :key_hash : nil
        end

        # 构造并缓存用于批量读取的 SQL 查询模板。
        # 目的是避免为不同数量的键重复生成 SQL 字符串。
        # 它先生成一个包含两个硬编码值的 IN 子句的 SQL，然后将硬编码值替换为相应数量的占位符 (?)。
        # 这种方法利用了 Active Record 的 SQL 生成能力，同时又允许动态调整 IN 子句的大小。
        def select_sql(keys)
          @select_sql ||= {}
          @select_sql[keys.count] ||= \
            where(key_hash: [ 1111, 2222 ]) # 使用任意两个值生成基础 SQL
              .select(:key, :value)
              .to_sql
              .gsub("1111, 2222", Array.new(keys.count, "?").join(", ")) # 替换为占位符
        end

        # 计算键的 SHA256 哈希，并将其解包为有符号的 64 位整数 (q>)。
        # 使用有符号整数是为了兼容 Postgresql 和 SQLite。
        def key_hash_for(key)
          Digest::SHA256.digest(key.to_s).unpack("q>").first
        end

        # 批量计算键的哈希值。
        def key_hashes_for(keys)
          keys.map { |key| key_hash_for(key) }
        end

        # 估算单行缓存数据的字节大小。
        def byte_size_for(payload)
          payload[:key].to_s.bytesize + payload[:value].to_s.bytesize + estimated_row_overhead
        end

        # 获取估算的行开销，如果启用了加密则加上加密开销。
        def estimated_row_overhead
          if SolidCache.configuration.encrypt?
            ESTIMATED_ROW_OVERHEAD + ESTIMATED_ENCRYPTION_OVERHEAD
          else
            ESTIMATED_ROW_OVERHEAD
          end
        end

        # 包装器方法，用于禁用查询缓存。
        def without_query_cache(&block)
          # uncached 是 Active Record 提供的禁用查询缓存的方法。
          # dirties: false 表示不将连接标记为"脏"，这可能在某些场景下避免不必要的连接切换。
          uncached(dirties: false, &block)
        end
    end
  end
end

# 触发 Active Support 的 load hook，允许其他代码扩展 Entry 类。
ActiveSupport.run_load_hooks :solid_cache_entry, SolidCache::Entry
