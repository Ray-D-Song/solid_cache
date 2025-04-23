# frozen_string_literal: true

module SolidCache
  module Connections
    # Sharded 类实现了多数据库分片的连接管理策略。
    class Sharded
      # 分片名称列表、节点（未使用？）、一致性哈希实例。
      attr_reader :names, :nodes, :consistent_hash

      # 初始化，接收分片名称列表。
      def initialize(names)
        @names = names
        # 创建 MaglevHash 实例，用于一致性哈希。
        @consistent_hash = MaglevHash.new(names)
      end

      # 在每个分片上执行代码块。
      # 如果没有块，返回枚举器。
      def with_each(&block)
        return enum_for(:with_each) unless block_given?

        names.each { |name| with(name, &block) }
      end

      # 在指定名称的分片上执行代码块。
      # 使用 Active Record 的 `with_shard` 方法切换连接。
      def with(name, &block)
        Record.with_shard(name, &block)
      end

      # 根据 key 确定分片，并在该分片上执行代码块。
      def with_connection_for(key, &block)
        with(shard_for(key), &block)
      end

      # 将一批 key (或包含 :key 的哈希) 按其目标分片分组。
      # 返回 { shard_name => [keys] } 的哈希。
      def assign(keys)
        keys.group_by { |key| shard_for(key.is_a?(Hash) ? key[:key] : key) }
      end

      # 返回分片的数量。
      def count
        names.count
      end

      private
        # 使用一致性哈希算法根据 key 计算目标分片的名称。
        def shard_for(key)
          consistent_hash.node(key)
        end
    end
  end
end
