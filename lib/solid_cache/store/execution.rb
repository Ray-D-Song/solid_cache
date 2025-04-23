# frozen_string_literal: true

module SolidCache
  class Store
    # Execution 模块负责管理操作的执行方式，特别是异步执行。
    # 它还控制是否禁用 Active Record 的 instrumentation。
    module Execution
      def initialize(options = {})
        super(options)
        # 初始化一个固定大小为 1 的线程池，用于异步执行任务。
        # 队列大小限制为 100，超出则丢弃任务。
        @background = Concurrent::FixedThreadPool.new(1, max_queue: 100, fallback_policy: :discard)
        # 从选项中获取是否启用 Active Record instrumentation (默认为 true)。
        @active_record_instrumentation = options.fetch(:active_record_instrumentation, true)
      end

      private
        # 将代码块放入后台线程池执行。
        def async(&block)
          # 必须立即获取当前分片，因为块将在不同的线程中执行。
          current_shard = Entry.current_shard
          # 将任务添加到线程池队列。
          @background << ->() do
            # 使用 Rails Executor 包装代码块，确保 Rails 环境 (如自动加载) 正确设置。
            wrap_in_rails_executor do
              # 在正确的数据库分片上执行。
              connections.with(current_shard) do
                # 设置 (或禁用) instrumentation 并执行实际的代码块。
                setup_instrumentation(&block)
              end
            end
          # 捕获异步任务中的异常，并调用配置的错误处理器。
          rescue Exception => exception
            error_handler&.call(method: :async, exception: exception, returning: nil)
          end
        end

        # 根据 async 参数决定是同步执行还是异步执行代码块。
        # 这个方法被 Connections 模块中的 with_* 方法调用。
        def execute(async, &block)
          if async
            async(&block)
          else
            # 同步执行：直接设置 instrumentation 并执行块。
            setup_instrumentation(&block)
          end
        end

        # 如果配置了全局的 SolidCache.executor，则使用它来包装代码块。
        # 否则直接执行代码块。
        def wrap_in_rails_executor(&block)
          if SolidCache.executor
            SolidCache.executor.wrap(&block)
          else
            block.call
          end
        end

        # 检查是否启用了 Active Record instrumentation。
        def active_record_instrumentation?
          @active_record_instrumentation
        end

        # 根据配置决定是否禁用 instrumentation 来执行代码块。
        def setup_instrumentation(&block)
          if active_record_instrumentation?
            # 启用 instrumentation (默认行为)。
            block.call
          else
            # 禁用 instrumentation。
            Record.disable_instrumentation(&block)
          end
        end
    end
  end
end
