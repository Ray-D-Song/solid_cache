# frozen_string_literal: true

module SolidCache
  # SolidCache::Store 类是 Solid Cache 的核心实现。
  # 它继承自 ActiveSupport::Cache::Store，并实现了标准的 Rails 缓存接口。
  class Store < ActiveSupport::Cache::Store
    # 引入了各种功能模块，将缓存的不同方面（API、连接、条目管理、执行、过期、故障安全、统计）分离。
    include Api, Connections, Entries, Execution, Expiry, Failsafe, Stats
    # 预置了 LocalCache 策略，通常用于在内存中缓存热点数据，减少对后端存储（SSD）的访问。
    prepend ActiveSupport::Cache::Strategy::LocalCache

    # 初始化方法，合并全局配置和传入的选项。
    def initialize(options = {})
      super(SolidCache.configuration.store_options.merge(options))
    end

    # 表明此缓存存储支持 Rails 的缓存版本控制。
    def self.supports_cache_versioning?
      true
    end

    # 设置方法，可能会执行一些初始化任务。
    # super 调用父类的 setup! 方法。
    def setup!
      super
    end
  end
end
