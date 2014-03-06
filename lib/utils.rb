# encoding: utf-8

class Object
  def symboliser
    if(self.class == Hash)
      p=Hash.new
      self.each do |k,v|
        newk=nil
        if k.class == Symbol
          newk = k
        elsif k.class == String
          if k.strip =~ /^\d+$/
            newk = k.strip.to_i
          elsif k.strip =~ /^\s+\.\s+/
            newk = k.strip.to_f
          elsif k.strip =~ /^[A-Z]/i
            newk = k.strip.to_sym
          else
            newk = ("_"+k.strip.to_s.gsub(/[^A-Z0-9_]/i, '_').gsub(/_+/, '_')).to_sym
          end
        else
          newk = k
        end
        p[newk]=v.symboliser
      end
      return p
    elsif self.class == Array
      return self.map{ |x| x.symboliser }
    else
      return self
    end
  end
end

module CustomerLogger
  def log(msg)
    Resque.logger.log(Logger::INFO, "CUSTOMER_BILLING :: #{msg}")
  end
end

module DataLogger
  def log(msg)
    Resque.logger.log(Logger::INFO, "DATA_BILLING :: #{msg}")
  end
end

class Hash
  def except(*keys)
    self.select{ |k, v| !keys.include?(k) }
  end
end

class Array
  def hashes_merge
    self.inject({}){ |i, j| i.merge(j) }
  end
end



