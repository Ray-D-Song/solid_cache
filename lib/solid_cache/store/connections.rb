# frozen_string_literal: true

module SolidCache
  class Store
    # Connections 模块负责管理数据库连接和分片逻辑。
    # 它根据配置初始化连接，并将缓存操作路由到正确的数据库分片。
    module Connections
      # 存储分片配置选项。
      attr_reader :shard_options

      def initialize(options = {})
        super(options)
        # 处理旧的 :clusters/:cluster 配置，兼容并发出弃用警告。
        if options[:clusters].present?
          if options[:clusters].size > 1
            raise ArgumentError, "Multiple clusters are no longer supported"
          else
            ActiveSupport.deprecator.warn(":clusters is deprecated, use :shards instead.")
          end
          @shard_options = options.fetch(:clusters).first[:shards]
        elsif options[:cluster].present?
          ActiveSupport.deprecator.warn(":cluster is deprecated, use :shards instead.")
          @shard_options = options.fetch(:cluster, {})[:shards]
        else
          # 获取 :shards 配置。
          @shard_options = options.fetch(:shards, nil)
        end

        # 校验 shards 配置是否为 Array 或 nil。
        if [ Array, NilClass ].none? { |klass| @shard_options.is_a? klass }
          raise ArgumentError, "`shards` is a `#{@shard_options.class.name}`, it should be Array or nil"
        end
      end

      # 在每个数据库连接上执行块。
      # 返回一个枚举器或执行块。
      # `async` 参数暗示可能支持异步执行 (具体实现在 `execute` 方法中)。
      def with_each_connection(async: false, &block)
        return enum_for(:with_each_connection) unless block_given?

        connections.with_each do
          execute(async, &block)
        end
      end

      # 获取或初始化 SolidCache::Connections 实例。
      def connections
        @connections ||= SolidCache::Connections.from_config(@shard_options)
      end

      private
        # 在 Store 初始化时确保连接被建立。
        def setup!
          connections
        end

        # 根据 key 确定分片，并在对应的连接上执行块。
        def with_connection_for(key, async: false, &block)
          connections.with_connection_for(key) do
            execute(async, &block)
          end
        end

        # 在指定名称的分片连接上执行块。
        def with_connection(name, async: false, &block)
          connections.with(name) do
            execute(async, &block)
          end
        end

        # 将一批 key/entry 根据其目标分片进行分组。
        def group_by_connection(keys)
          connections.assign(keys)
        end

        # 获取所有分片的名称。
        def connection_names
          connections.names
        end

        # 包装读取单个 key 的操作，确保在正确的分片上执行，并包含 failsafe 逻辑。
        def reading_key(key, failsafe:, failsafe_returning: nil, &block)
          failsafe(failsafe, returning: failsafe_returning) do
            with_connection_for(key, &block)
          end
        end

        # 包装读取多个 key 的操作。
        # 先将 keys 按分片分组，然后在每个分片上执行读取操作，并包含 failsafe 逻辑。
        def reading_keys(keys, failsafe:, failsafe_returning: nil)
          group_by_connection(keys).map do |connection, grouped_keys|
            failsafe(failsafe, returning: failsafe_returning) do
              with_connection(connection) do
                yield grouped_keys # 将分组后的 keys 传给块 (通常是 Entry.read_multi)。
              end
            end
          end
        end

        # 包装写入单个 key 的操作，确保在正确的分片上执行，并包含 failsafe 逻辑。
        def writing_key(key, failsafe:, failsafe_returning: nil, &block)
          failsafe(failsafe, returning: failsafe_returning) do
            with_connection_for(key, &block)
          end
        end

        # 包装写入多个 entry 的操作。
        # 先将 entries 按分片分组，然后在每个分片上执行写入操作，并包含 failsafe 逻辑。
        def writing_keys(entries, failsafe:, failsafe_returning: nil)
          # 注意：这里传入的是 entries (通常是 { key:, value: } 的哈希数组)
          # group_by_connection 需要能处理这种情况，或者 entries 需要先提取 key。
          group_by_connection(entries).map do |connection, grouped_entries|
            failsafe(failsafe, returning: failsafe_returning) do
              with_connection(connection) do
                yield grouped_entries # 将分组后的 entries 传给块 (通常是 Entry.write_multi)。
              end
            end
          end
        end

        # 包装需要在所有分片上执行的写入操作 (如 clear)。
        # 在每个分片连接上执行块，并包含 failsafe 逻辑。
        # 返回第一个分片操作的结果 (可能是为了兼容性或简化)。
        def writing_all(failsafe:, failsafe_returning: nil, &block)
          connection_names.map do |connection|
            failsafe(failsafe, returning: failsafe_returning) do
              with_connection(connection, &block)
            end
          end.first
        end
    end
  end
end
