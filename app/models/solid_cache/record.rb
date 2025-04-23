# frozen_string_literal: true

module SolidCache
  # Record 是 Solid Cache 所有 Active Record 模型 (目前只有 Entry) 的基类。
  # 它配置数据库连接和分片行为。
  class Record < ActiveRecord::Base
    # 一个空的 instrumenter，用于禁用 Active Record 的 instrumentation。
    NULL_INSTRUMENTER = ActiveSupport::Notifications::Instrumenter.new(ActiveSupport::Notifications::Fanout.new)

    # 将此类标记为抽象类，意味着它不会有对应的数据库表。
    self.abstract_class = true

    # 根据全局配置连接到指定的数据库或分片。
    # `SolidCache.configuration.connects_to` 返回传递给 `connects_to` 的参数哈希。
    connects_to(**SolidCache.configuration.connects_to) if SolidCache.configuration.connects_to

    class << self
      # 临时禁用 Active Record 的 instrumentation (如 SQL 查询日志)。
      def disable_instrumentation(&block)
        with_instrumenter(NULL_INSTRUMENTER, &block)
      end

      # 使用指定的 instrumenter 执行代码块。
      # 这允许暂时替换掉默认的 Active Record instrumenter。
      # 兼容不同 Rails 版本下设置 instrumenter 的方式。
      def with_instrumenter(instrumenter, &block)
        if connection.respond_to?(:with_instrumenter)
          # 较新 Rails 版本的方式
          connection.with_instrumenter(instrumenter, &block)
        else
          # 较旧 Rails 版本的方式 (通过 IsolatedExecutionState)
          begin
            old_instrumenter, ActiveSupport::IsolatedExecutionState[:active_record_instrumenter] = ActiveSupport::IsolatedExecutionState[:active_record_instrumenter], instrumenter
            block.call
          ensure
            ActiveSupport::IsolatedExecutionState[:active_record_instrumenter] = old_instrumenter
          end
        end
      end

      # 在指定的分片上执行代码块。
      # 如果提供了 shard 名称并且全局配置启用了分片，则使用 `connected_to` 切换分片。
      # 否则，直接执行块 (在当前连接或默认连接上)。
      def with_shard(shard, &block)
        if shard && SolidCache.configuration.sharded?
          # `connected_to` 是 Active Record 用于切换数据库连接/分片的方法。
          # `role: default_role` 和 `prevent_writes: false` 是 `connected_to` 的标准参数。
          connected_to(shard: shard, role: default_role, prevent_writes: false, &block)
        else
          block.call
        end
      end

      # 在每个配置的分片上依次执行代码块。
      # 如果未配置分片，则只执行一次块。
      def each_shard(&block)
        return to_enum(:each_shard) unless block_given?

        if SolidCache.configuration.sharded?
          SolidCache.configuration.shard_keys.each do |shard|
            Record.with_shard(shard, &block)
          end
        else
          yield
        end
      end
    end
  end
end

# 触发 Active Support 的 load hook，允许其他代码扩展 Record 类。
ActiveSupport.run_load_hooks :solid_cache, SolidCache::Record
