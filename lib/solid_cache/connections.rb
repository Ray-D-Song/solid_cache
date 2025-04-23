# frozen_string_literal: true

module SolidCache
  # Connections 模块提供了一个工厂方法 `from_config`，用于根据配置创建合适的连接管理器。
  module Connections
    # 工厂方法，根据传入的 options (来自 Store 的 shard_options) 和全局配置，
    # 返回一个具体的连接管理实例 (Unmanaged, Single, 或 Sharded)。
    def self.from_config(options)
      # 判断是否需要分片逻辑 (根据 options 或全局配置)。
      if options.present? || SolidCache.configuration.sharded?
        case options
        when NilClass
          # 如果 options 为 nil，则使用全局配置中定义的所有分片名称。
          names = SolidCache.configuration.shard_keys
        when Array
          # 如果 options 是数组，则使用数组中指定的分片名称。
          names = options.map(&:to_sym)
        end

        # 检查指定的分片名称是否都在全局配置中定义过。
        if (unknown_shards = names - SolidCache.configuration.shard_keys).any?
          raise ArgumentError, "Unknown #{"shard".pluralize(unknown_shards)}: #{unknown_shards.join(", ")}"
        end

        # 根据分片数量选择策略：
        if names.size == 1
          # 单个分片：使用 Single 策略。
          Single.new(names.first)
        else
          # 多个分片：使用 Sharded 策略。
          Sharded.new(names)
        end
      else
        # 没有配置分片：使用 Unmanaged 策略 (可能使用默认连接)。
        Unmanaged.new
      end
    end
  end
end
