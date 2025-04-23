# frozen_string_literal: true

module SolidCache
  class Store
    # Api 模块负责实现 Rails 定义的 Cache Store API。
    # 它包含了如 read, write, delete, increment, decrement, read_multi, write_multi 等核心缓存操作方法。
    module Api
      # 默认键的最大字节数限制。
      DEFAULT_MAX_KEY_BYTESIZE = 1024
      # SQL LIKE 查询中需要转义的通配符。
      SQL_WILDCARD_CHARS = [ "_", "%" ]

      attr_reader :max_key_bytesize

      def initialize(options = {})
        super(options)
        # 从选项中获取或使用默认的最大键字节数。
        @max_key_bytesize = options.fetch(:max_key_bytesize, DEFAULT_MAX_KEY_BYTESIZE)
      end

      # 实现缓存值的原子增加操作。
      def increment(name, amount = 1, options = nil)
        options = merged_options(options)
        key = normalize_key(name, options)

        # 使用 ActiveSupport::Notifications 进行 instrument，方便监控和日志记录。
        instrument :increment, key, amount: amount do
          # 调用 adjust 方法执行实际的增加逻辑。
          adjust(name, amount, options)
        end
      end

      # 实现缓存值的原子减少操作。
      def decrement(name, amount = 1, options = nil)
        options = merged_options(options)
        key = normalize_key(name, options)

        instrument :decrement, key, amount: amount do
          # 调用 adjust 方法执行实际的减少逻辑。
          adjust(name, -amount, options)
        end
      end

      # Solid Cache 目前不支持 cleanup 操作 (通常用于清理命名空间下的所有缓存)。
      def cleanup(options = nil)
        raise NotImplementedError.new("#{self.class.name} does not support cleanup")
      end

      # 清空整个缓存。
      def clear(options = nil)
        # 调用 entry_clear 方法 (可能定义在 Entries 模块中) 执行清空操作。
        entry_clear
      end

      private
        # 读取单个缓存条目。
        # 它首先读取序列化后的条目，然后反序列化。
        def read_entry(key, **options)
          deserialize_entry(read_serialized_entry(key, **options), **options)
        end

        # 读取序列化后的缓存条目。
        # 调用 entry_read 方法 (可能定义在 Entries 模块中)。
        def read_serialized_entry(key, **options)
          entry_read(key)
        end

        # 写入单个缓存条目。
        def write_entry(key, entry, raw: false, unless_exist: false, **options)
          # 将 entry 对象序列化。
          payload = serialize_entry(entry, raw: raw, **options)

          # 如果 unless_exist 为 true，则只在键不存在或已过期时写入。
          if unless_exist
            written = false
            # 使用 entry_lock_and_write 加锁并写入，保证原子性。
            entry_lock_and_write(key) do |value|
              if value.nil? || deserialize_entry(value, **options).expired?
                written = true
                payload
              end
            end
          else
            # 直接调用 entry_write 写入。
            written = entry_write(key, payload)
          end

          # 这个方法似乎只是返回写入是否成功，没有实际写入操作？
          # 可能是为了触发 LocalCache 更新。
          write_serialized_entry(key, payload, raw: raw, returning: written, **options)
          written
        end

        # 这个方法名容易引起误解，它并不直接写入序列化条目，而是返回传入的 `returning` 值。
        # 其主要作用可能是为了与 LocalCache 交互或提供扩展点。
        def write_serialized_entry(key, payload, raw: false, unless_exist: false, expires_in: nil, race_condition_ttl: nil, returning: true, **options)
          returning
        end

        # 读取多个序列化后的缓存条目。
        # 调用 entry_read_multi 方法。
        def read_serialized_entries(keys)
          entry_read_multi(keys).reduce(&:merge!)
        end

        # 读取多个缓存条目，处理版本匹配和过期检查。
        def read_multi_entries(names, **options)
          # 将名称规范化为键。
          keys_and_names = names.index_by { |name| normalize_key(name, options) }
          # 批量读取序列化的条目。
          serialized_entries = read_serialized_entries(keys_and_names.keys)

          keys_and_names.each_with_object({}) do |(key, name), results|
            serialized_entry = serialized_entries[key]
            # 反序列化。
            entry = deserialize_entry(serialized_entry, **options)

            next unless entry

            # 检查版本。
            version = normalize_version(name, options)

            # 检查是否过期。
            if entry.expired?
              delete_entry(key, **options)
            # 检查版本是否匹配。
            elsif !entry.mismatched?(version)
              # 处理可能的反序列化错误。
              if defined? ActiveSupport::Cache::DeserializationError
                begin
                  results[name] = entry.value
                rescue ActiveSupport::Cache::DeserializationError
                end
              else
                results[name] = entry.value
              end
            end
          end
        end

        # 写入多个缓存条目。
        def write_multi_entries(entries, expires_in: nil, **options)
          if entries.any?
            # 批量序列化条目。
            serialized_entries = serialize_entries(entries, **options)
            # 更新本地缓存 (LocalCache)。
            serialized_entries.each do |entry_hash| # 修正变量名以更清晰
              write_serialized_entry(entry_hash[:key], entry_hash[:value]) # 使用 :key 和 :value
            end

            # 调用 entry_write_multi 批量写入后端存储。
            entry_write_multi(serialized_entries).all?
          end
        end

        # 删除单个缓存条目。
        # 调用 entry_delete 方法。
        def delete_entry(key, **options)
          entry_delete(key)
        end

        # 删除多个缓存条目。
        # 调用 entry_delete_multi 方法。
        def delete_multi_entries(entries, **options)
          entry_delete_multi(entries).compact.sum
        end

        # 序列化单个缓存条目。
        # 调用父类 (ActiveSupport::Cache::Store) 的序列化方法。
        def serialize_entry(entry, raw: false, **options)
          super(entry, raw: raw, **options)
        end

        # 批量序列化缓存条目。
        def serialize_entries(entries, **options)
          entries.map do |key, entry|
            { key: key, value: serialize_entry(entry, **options) }
          end
        end

        # 反序列化单个缓存条目。
        # 调用父类的反序列化方法。
        def deserialize_entry(payload, **)
          super(payload)
        end

        # 规范化键名，并进行截断处理。
        def normalize_key(key, options)
          # 调用父类的 normalize_key，然后转为二进制，再进行截断。
          truncate_key super&.b
        end

        # 如果键的字节长度超过限制，进行截断并在末尾附加哈希值以避免冲突。
        def truncate_key(key)
          if key && key.bytesize > max_key_bytesize
            suffix = ":hash:#{ActiveSupport::Digest.hexdigest(key)}"
            truncate_at = max_key_bytesize - suffix.bytesize
            "#{key.byteslice(0, truncate_at)}#{suffix}".b
          else
            key
          end
        end

        # 原子调整 (增加/减少) 缓存值的内部逻辑。
        def adjust(name, amount, options)
          options = merged_options(options)
          key = normalize_key(name, options)

          # 使用 entry_lock_and_write 获取锁并执行写操作。
          new_value = entry_lock_and_write(key) do |value|
            # 序列化调整后的新条目。
            serialize_entry(adjusted_entry(value, amount, options))
          end
          # 如果写入成功，反序列化新值并返回。
          deserialize_entry(new_value, **options).value if new_value
        end

        # 计算调整后的缓存条目。
        def adjusted_entry(value, amount, options)
          entry = deserialize_entry(value, **options)

          # 如果现有条目有效且未过期，则在其值基础上进行调整。
          if entry && !entry.expired?
            ActiveSupport::Cache::Entry.new \
              amount + entry.value.to_i, **options.dup.merge(expires_in: nil, expires_at: entry.expires_at)
          # 兼容旧的原始数值格式。
          elsif /\A\d+\z/.match?(value)
            ActiveSupport::Cache::Entry.new(amount + value.to_i, **options)
          else
            # 如果条目不存在或已过期，则创建一个新的条目。
            ActiveSupport::Cache::Entry.new(amount, **options)
          end
        end
    end
  end
end
