# frozen_string_literal: true

module SolidCache
  class Store
    # Failsafe 模块提供了错误处理和容错机制。
    # 它主要用于捕获和处理与数据库交互时可能发生的瞬时错误。
    module Failsafe
      # 定义了一组被认为是"瞬时"的 Active Record 错误。
      # 这些错误通常表示临时的数据库问题 (如超时、死锁)，重试或忽略可能是合适的。
      TRANSIENT_ACTIVE_RECORD_ERRORS = [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionNotEstablished,
        ActiveRecord::Deadlocked,
        ActiveRecord::LockWaitTimeout,
        ActiveRecord::QueryCanceled,
        ActiveRecord::StatementTimeout
      ]

      # 默认的错误处理器。
      # 如果配置了 Logger，则记录错误信息。
      DEFAULT_ERROR_HANDLER = ->(method:, returning:, exception:) do
        if Store.logger
          Store.logger.error { "SolidCacheStore: #{method} failed, returned #{returning.inspect}: #{exception.class}: #{exception.message}" }
        end
      end

      def initialize(options = {})
        super(options)
        # 获取用户配置的错误处理器，如果未配置则使用默认处理器。
        @error_handler = options.fetch(:error_handler, DEFAULT_ERROR_HANDLER)
      end

      private
        attr_reader :error_handler

        # 包裹可能抛出数据库错误的代码块。
        # `method`: 当前操作的名称 (用于日志记录)。
        # `returning`: 发生错误时应返回的值。
        def failsafe(method, returning: nil)
          yield # 执行原始代码块
        # 捕获定义的瞬时 Active Record 错误。
        rescue *TRANSIENT_ACTIVE_RECORD_ERRORS => error
          # 如果应用配置了 Active Support 的错误报告器，则报告此错误。
          ActiveSupport.error_reporter&.report(error, handled: true, severity: :warning)
          # 调用配置的错误处理器。
          error_handler&.call(method: method, exception: error, returning: returning)
          # 返回指定的默认值。
          returning
        end
    end
  end
end
