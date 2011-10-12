unless Object.new.respond_to? :to_query and Object.new.respond_to? :to_param
  class Object
    def to_param
      to_s
    end

    def to_query(key)
      include Riak::Util::Escape
      "#{escape(key.to_s)}=#{escape(to_param.to_s)}"
    end
  end

  class Array
    def to_param
      map(&:to_param).join('/')
    end

    def to_query(key)
      prefix = "#{key}[]"
      collect { |value| value.to_query(prefix) }.join '&'
    end
  end

  class Hash
    def to_param(namespace = nil)
      collect do |key, value|
        value.to_query(namespace ? "#{namespace}[#{key}]" : key)
      end.sort * '&'
    end
  end
end
