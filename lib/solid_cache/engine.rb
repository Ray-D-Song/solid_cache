# frozen_string_literal: true

require "active_support"
require "active_record"

module SolidCache
  # SolidCache::Engine 定义了 Solid Cache 作为 Rails Engine 的行为。
  # Engine 负责在 Rails 应用启动过程中初始化配置、设置执行器等。
  class Engine < ::Rails::Engine
    # 将 Engine 的命名空间与主应用隔离。
    isolate_namespace SolidCache

    # 为 Solid Cache 提供配置选项的命名空间。
    # 允许在 `config/environments/*.rb` 中通过 `config.solid_cache.xxx = ...` 进行配置。
    config.solid_cache = ActiveSupport::OrderedOptions.new

    # 初始化器：加载和处理 Solid Cache 的配置。
    # 在 Rails 的 :initialize_cache 步骤之前运行。
    initializer "solid_cache.config", before: :initialize_cache do |app|
      # 定义可能的配置文件路径。
      config_paths = %w[config/cache config/solid_cache]

      # 将这些路径添加到 Rails 应用的路径中，并允许通过环境变量 SOLID_CACHE_CONFIG 指定配置文件。
      config_paths.each do |path|
        app.paths.add path, with: ENV["SOLID_CACHE_CONFIG"] || "#{path}.yml"
      end

      # 查找实际存在的配置文件。
      config_pathname = config_paths.map { |path| Pathname.new(app.config.paths[path].first) }.find(&:exist?)

      # 如果找到配置文件，则加载并将其转换为深度符号化的哈希。
      options = config_pathname ? app.config_for(config_pathname).to_h.deep_symbolize_keys : {}

      # 合并来自 `config.solid_cache` 的配置项 (如果存在)。
      # 这允许通过环境配置文件覆盖 YML 文件中的设置。
      options[:connects_to] = config.solid_cache.connects_to if config.solid_cache.connects_to
      options[:size_estimate_samples] = config.solid_cache.size_estimate_samples if config.solid_cache.size_estimate_samples
      options[:encrypt] = config.solid_cache.encrypt if config.solid_cache.encrypt
      options[:encryption_context_properties] = config.solid_cache.encryption_context_properties if config.solid_cache.encryption_context_properties

      # 使用合并后的选项创建全局的 SolidCache::Configuration 实例。
      SolidCache.configuration = SolidCache::Configuration.new(**options)

      # 移除对已弃用的 key_hash_stage 配置的警告。
      if config.solid_cache.key_hash_stage
        ActiveSupport.deprecator.warn("config.solid_cache.key_hash_stage is deprecated and has no effect.")
      end
    end

    # 初始化器：设置 Solid Cache 使用的执行器 (Executor)。
    # 在 Rails 的 :run_prepare_callbacks 步骤之前运行。
    initializer "solid_cache.app_executor", before: :run_prepare_callbacks do |app|
      # 优先使用 `config.solid_cache.executor` 指定的执行器，否则使用 Rails 应用的默认执行器。
      # 执行器用于包装后台任务 (如异步过期)，确保 Rails 环境正确加载。
      SolidCache.executor = config.solid_cache.executor || app.executor
    end

    # 在 Rails 应用完全初始化后运行。
    # 如果 Rails.cache 配置为 SolidCache::Store，则调用其 setup! 方法。
    config.after_initialize do
      Rails.cache.setup! if Rails.cache.is_a?(Store)
    end

    # 在 Rails 应用完全初始化后运行。
    # 检查加密配置与数据库/Rails 版本的兼容性。
    config.after_initialize do
      if SolidCache.configuration.encrypt? && Record.connection.adapter_name == "PostgreSQL" && Rails::VERSION::MAJOR <= 7
        # Rails 7 及更早版本在 PostgreSQL 上加密二进制列存在问题。
        raise \
          "Cannot enable encryption for Solid Cache: in Rails 7, Active Record Encryption does not support " \
          "encrypting binary columns on PostgreSQL"
      end
    end
  end
end
