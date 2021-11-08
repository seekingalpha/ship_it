require 'csv'

# Manages reading/writing a list of branches
module BranchList
  def self.read fname
    if File.exist?(fname)
      parse(IO.read(fname))
    else
      []
    end
  end

  def self.parse data
    CSV.new(data).read.uniq
  end

  def self.dump list
    CSV.generate do |csv|
      list.uniq.each do |line|
        csv << line
      end
    end
  end

  def self.write fname, list
    File.open(fname, 'w') {|f| f.write dump(list)}
  end
end
