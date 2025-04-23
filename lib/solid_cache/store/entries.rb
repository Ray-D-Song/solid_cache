# frozen_string_literal: true

module SolidCache
  class Store
    # Entries 模块封装了对 SolidCache::Entry (Active Record 模型) 的直接数据库操作。
    # 它提供了缓存条目的底层读写、删除、清空和加锁方法。
    module Entries
      # 决定清空缓存时使用 :truncate 还是 :delete。
      attr_reader :clear_with

      def initialize(options = {})
        super(options)

        # Truncating 在 MySQL 的事务测试中可能会有问题，因此测试环境下默认使用 :delete。
        @clear_with = options.fetch(:clear_with) { Rails.env.test? ? :delete : :truncate }&.to_sym

        # 校验 clear_with 参数的有效性。
        unless [ :truncate, :delete ].include?(clear_with)
          raise ArgumentError, "`clear_with` must be either ``:truncate`` or ``:delete`"
        end
      end

      private
        # 清空缓存条目。
        # 使用 writing_all 方法确保在所有分片/连接上执行。
        # 根据 clear_with 选项调用 Entry.clear_truncate 或 Entry.clear_delete。
        def entry_clear
          writing_all(failsafe: :clear, failsafe_returning: nil) do
            if clear_with == :truncate
              Entry.clear_truncate
            else
              Entry.clear_delete
            end
          end
        end

        # 加锁并写入缓存条目，用于实现原子操作如 increment/decrement。
        # 使用 writing_key 方法确保在正确的数据库分片上执行。
        def entry_lock_and_write(key, &block)
          writing_key(key, failsafe: :increment) do
            # 调用 Entry.lock_and_write 获取数据库行锁并执行块。
            Entry.lock_and_write(key) do |value|
              # 执行传入的块 (通常在 Api#adjust 中定义)，如果块返回真值 (表示写入发生)，则追踪写入次数。
              block.call(value).tap { |result| track_writes(1) if result }
            end
          end
        end

        # 读取单个缓存条目。
        # 使用 reading_key 方法确保在正确的数据库分片上读取。
        def entry_read(key)
          reading_key(key, failsafe: :read_entry) do
            Entry.read(key)
          end
        end

        # 批量读取缓存条目。
        # 使用 reading_keys 方法确保在正确的数据库分片上读取。
        def entry_read_multi(keys)
          reading_keys(keys, failsafe: :read_multi_mget, failsafe_returning: {}) do |keys|
            Entry.read_multi(keys)
          end
        end

        # 写入单个缓存条目。
        # 使用 writing_key 方法确保在正确的数据库分片上写入。
        def entry_write(key, payload)
          writing_key(key, failsafe: :write_entry, failsafe_returning: nil) do
            Entry.write(key, payload)
            # 追踪写入次数。
            track_writes(1)
            true # 返回 true 表示写入成功。
          end
        end

        # 批量写入缓存条目。
        # 使用 writing_keys 方法确保在正确的数据库分片上写入。
        def entry_write_multi(entries)
          writing_keys(entries, failsafe: :write_multi_entries, failsafe_returning: false) do |entries|
            Entry.write_multi(entries)
            # 追踪写入次数。
            track_writes(entries.count)
            true # 返回 true 表示写入成功。
          end
        end

        # 删除单个缓存条目。
        # 使用 writing_key 方法确保在正确的数据库分片上删除。
        def entry_delete(key)
          writing_key(key, failsafe: :delete_entry, failsafe_returning: false) do
            # Entry.delete_by_key 返回删除的行数，大于 0 表示成功。
            Entry.delete_by_key(key) > 0
          end
        end

        # 批量删除缓存条目。
        # 使用 writing_keys 方法确保在正确的数据库分片上删除。
        def entry_delete_multi(entries)
          writing_keys(entries, failsafe: :delete_multi_entries, failsafe_returning: 0) do
            # 返回成功删除的总行数。
            Entry.delete_by_key(*entries)
          end
        end
    end
  end
end
