# frozen_string_literal: true

module SolidCache
  module Connections
    # Unmanaged 类实现了不进行显式连接管理的策略。
    # 它假定所有操作都在当前的 Active Record 连接上执行，不进行任何切换。
    class Unmanaged
      # 直接执行块，不切换连接。
      def with_each
        return enum_for(:with_each) unless block_given?

        yield
      end

      # 直接执行块，忽略 name 参数。
      def with(name)
        yield
      end

      # 直接执行块，忽略 key 参数。
      def with_connection_for(key)
        yield
      end

      # 将所有 key 分配给一个虚拟的 `:default` 分片。
      # 这主要是为了 API 兼容性，实际操作仍在当前连接执行。
      def assign(keys)
        { default: keys }
      end

      # 报告分片数量为 1 (虚拟的 default 分片)。
      def count
        1
      end

      # 报告分片名称为 [:default]。
      def names
        [ :default ]
      end
    end
  end
end
