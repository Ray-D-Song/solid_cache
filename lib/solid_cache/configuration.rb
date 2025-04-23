# frozen_string_literal: true

module SolidCache
  # Configuration 类负责存储和处理 Solid Cache 的所有配置选项。
  # 这些选项在 Rails Engine 初始化时从配置文件和环境配置中加载。
  class Configuration
    # store_options: 传递给 ActiveSupport::Cache::Store 父类的选项。
    # connects_to: Active Record `connects_to` 方法所需的数据库连接/分片配置。
    # executor: 用于后台任务的执行器。
    # size_estimate_samples: 估算缓存大小时使用的样本数量。
    # encrypt: 是否启用加密。
    # encryption_context_properties: 传递给 Active Record `encrypts` 方法的加密选项。
    attr_reader :store_options, :connects_to, :executor, :size_estimate_samples, :encrypt, :encryption_context_properties

    def initialize(store_options: {}, database: nil, databases: nil, connects_to: nil, executor: nil, encrypt: false, encryption_context_properties: nil, size_estimate_samples: 10_000)
      @store_options = store_options
      @size_estimate_samples = size_estimate_samples
      @executor = executor
      @encrypt = encrypt
      @encryption_context_properties = encryption_context_properties
      # 如果启用了加密但未提供加密上下文属性，则使用默认值。
      @encryption_context_properties ||= default_encryption_context_properties if encrypt?
      # 处理并设置数据库连接配置。
      set_connects_to(database: database, databases: databases, connects_to: connects_to)
    end

    # 判断是否配置了分片。
    def sharded?
      connects_to && connects_to[:shards]
    end

    # 获取所有分片的名称 (keys)。
    def shard_keys
      sharded? ? connects_to[:shards].keys : []
    end

    # 判断是否启用了加密。
    def encrypt?
      encrypt.present?
    end

    private
      # 处理 :database, :databases, :connects_to 选项，将其转换为 Active Record `connects_to` 所需的格式。
      # 确保这三个选项中只有一个被指定。
      def set_connects_to(database:, databases:, connects_to:)
        if [database, databases, connects_to].compact.size > 1
          raise ArgumentError, "You can only specify one of :database, :databases, or :connects_to"
        end

        @connects_to =
          case
          when database
            # 单个数据库配置。
            { shards: { database.to_sym => { writing: database.to_sym } } }
          when databases
            # 多个数据库配置 (每个数据库作为一个分片)。
            { shards: databases.map(&:to_sym).index_with { |db| { writing: db } } }
          when connects_to
            # 直接使用用户提供的 `connects_to` 配置。
            connects_to
          else
            # 没有指定数据库配置。
            nil
          end
      end

      # 提供默认的 Active Record 加密上下文属性。
      def default_encryption_context_properties
        require "active_record/encryption/message_pack_message_serializer"

        {
          # 配置加密器，禁用压缩 (因为 Solid Cache 的值可能已经是序列化/压缩过的)。
          encryptor: ActiveRecord::Encryption::Encryptor.new(compress: false),
          # 使用 MessagePack 序列化器，它比默认的序列化器更高效地处理二进制数据。
          message_serializer: ActiveRecord::Encryption::MessagePackMessageSerializer.new
        }
      end
  end
end
