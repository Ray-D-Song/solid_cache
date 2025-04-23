# frozen_string_literal: true

module SolidCache
  module Connections
    # Single 类实现了单数据库分片的连接管理策略。
    # 所有操作都定向到这个唯一配置的分片。
    class Single
      # 存储唯一的分片名称。
      attr_reader :name

      def initialize(name)
        @name = name
      end

      # 在唯一的分片上执行代码块。
      def with_each(&block)
        return enum_for(:with_each) unless block_given?

        with(name, &block)
      end

      # 在指定名称（也就是唯一名称）的分片上执行代码块。
      # 使用 Active Record 的 `with_shard` 方法切换连接。
      def with(name, &block)
        Record.with_shard(name, &block)
      end

      # 无论 key 是什么，都在唯一的分片上执行代码块。
      def with_connection_for(key, &block)
        with(name, &block)
      end

      # 将所有 key 分配给唯一的分片。
      # 返回 { shard_name => keys } 的哈希。
      def assign(keys)
        { name => keys }
      end

      # 分片数量始终为 1。
      def count
        1
      end

      # 返回包含唯一分片名称的数组。
      def names
        [ name ]
      end
    end
  end
end
