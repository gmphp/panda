class ActiveRecord::Base
  # set_primary_key "key"
  before_create :set_key
  
  def set_key
    self.id = UUID.timestamp_create().to_s
  end
end