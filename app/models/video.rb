class Video < SimpleDB::Base
  class VideoError < StandardError; end
  class NotValid < VideoError; end
  class NoFileSubmitted < VideoError; end
  class FormatNotRecognised < VideoError; end
  class ClippingError < VideoError; end
  class EncodingError < VideoError; end

  include LocalStore
  
  set_domain Panda::Config[:sdb_videos_domain]
  properties :filename, :original_filename, :parent, :status, :duration, :container, :width, :height, :video_codec, :video_bitrate, :fps, :audio_codec, :audio_bitrate, :audio_sample_rate, :profile, :profile_title, :player, :queued_at, :started_encoding_at, :encoding_time, :encoded_at, :updated_at, :created_at, :thumbnail_position

  # Generally you'll want to call like this:
  # Video.encode_next(
  #   :processing => lambda { |video|
  #     Notification.add_video(video)
  #   },
  #   :error => lambda { |video|
  #     Notification.add_video(video)
  #   },
  #   :success => lambda { |video|
  #     Notification.add_video(video)
  #   }
  # )
  def self.encode_next(callbacks={})
    raise ArgumentError, "Video.encode_next receives a hash of callbacks: :begin, :success and :error." unless callbacks.is_a?(Hash)
    raise ArgumentError, "callbacks should all receive one argument" unless callbacks.values.all? {|c| c.arity == 1}
    # Wait a bit for SDB
    sleep 4
    if video = Video.next_job
      # Wait longer for the file to arrive on S3
      sleep 5 if Panda::Config[:videos_store] == :s3
      begin
        video.status = "processing"
        video.save
        callbacks[:processing].call(video) if callbacks.has_key?(:processing)
        video.encode!
        callbacks[:success].call(video) if callbacks.has_key?(:success)
        return video
      rescue EncodingError
        callbacks[:error].call(video) if callbacks.has_key?(:error)
        return false
      rescue Object => e
        puts "#{e.inspect}\n#{e.backtrace.join("\n")}"
        Notification.add_program_error("Error encoding #{video.key}

          PARENT ATTRS
          ==================================================
          #{video.parent_video.attributes.to_h.to_yaml}
          ==================================================

          ENCODING ATTRS
          ==================================================
          #{video.attributes.to_h.to_yaml}
          ==================================================
          

          RUBY ERROR:
          ==================================================
          #{e.to_s}
          #{e.backtrace[0..19].join("\n")}
          ==================================================
          ".gsub(/\n */,"\n")
        )
        return false
      end
    else
      return nil
    end
  end
  
  # TODO: state machine for status
  # An original video can either be 'empty' if it hasn't had the video file uploaded, or 'original' if it has
  # An encoding will have it's original attribute set to the key of the original parent, and a status of 'queued', 'processing', 'success', or 'error'
  
  def self.create_empty
    video = Video.create
    video.status = 'empty'
    video.save
    
    return video
  end
  
  def to_sym
    'videos'
  end
  
  def clipping(position = nil)
    Clipping.new(self, position)
  end
  
  def clippings
    self.thumbnail_percentages.map do |p|
      Clipping.new(self, p)
    end
  end
  
  # Classification
  # ==============
  
  def encoding?
    ['queued', 'processing', 'success', 'error'].include?(self.status)
  end
  
  def parent?
    ['original', 'empty'].include?(self.status)
  end
  
  # Finders
  # =======
  
  # Only parent videos (no encodings)
  def self.all
    self.query("['status' = 'original'] intersection ['created_at' != ''] sort 'created_at' desc", :load_attrs => true) # TODO: Don't throw an exception if attrs for a record in the search can't be found - it probably means its just been deleted
  end

  def self.each_successful_encoding_since(datetime=nil, &block)
    self.each("['status' = 'success'] and ['created_at' >= '#{datetime.strftime("%Y-%M-%D")}']", &block)
  end
  def self.each_successful_encoding(&block)
    self.each("['status' = 'success']", &block)
  end
  
  def self.recent_videos
    self.query("['status' = 'original']", :max_results => 10, :load_attrs => true)
  end
  
  def self.recent_encodings
    self.query("['status' = 'success']", :max_results => 10, :load_attrs => true)
  end
  
  def self.queued_encodings
    self.query("['status' = 'processing' or 'status' = 'queued']", :load_attrs => true)
  end
  
  def self.next_job
    # TODO: change to outstanding_jobs and remove .first
    self.query("['status' = 'queued']").first
  end
  
  # def self.recently_completed_videos
  #   self.query("['status' = 'success']")
  # end
  
  def parent_video
    self.class.find(parent) if encoding? && !self.parent.nil?
  end
  
  def encodings
    self.class.query("['parent' = '#{self.key}']")
  end
  
  def successful_encodings
    self.class.query("['parent' = '#{self.key}'] intersection ['status' = 'success']")
  end
  
  def find_encoding_for_profile(p)
    self.class.query("['parent' = '#{self.key}'] intersection ['profile' = '#{p.key}']")
  end
  
  # Attr helpers
  # ============
  
  # Delete an original video and all it's encodings.
  def obliterate!
    # TODO: should this raise an exception if the file does not exist?
    self.delete_from_store
    self.encodings.each do |e|
      e.delete_from_store
      e.destroy!
    end
    self.destroy!
  end

  # Location to store video file fetched from S3 for encoding
  def tmp_filepath
    private_filepath(self.filename)
  end
  
  # Has the actual video file been uploaded for encoding?
  def empty?
    self.status == 'empty'
  end
  
  def state_update_url
    Panda::Config[:state_update_url].gsub(/\:video_file_id/,self.key)
  end
  
  def duration_str
    s = (self.duration.to_i || 0) / 1000
    "#{sprintf("%02d", s/60)}:#{sprintf("%02d", s%60)}"
  end
  
  def resolution
    self.width ? "#{self.width}x#{self.height}" : nil
  end
  
  def video_bitrate_in_bits
    self.video_bitrate.to_i * 1024
  end
  
  def audio_bitrate_in_bits
    self.audio_bitrate.to_i * 1024
  end
  
  # Encding attr helpers
  # ====================
  
  def url
    Store.url(self.filename)
  end
  
  def embed_html
    return nil unless self.encoding?
    %(<embed src="#{Store.url('flvplayer.swf')}" width="#{self.width}" height="#{self.height}" allowfullscreen="true" allowscriptaccess="always" flashvars="&displayheight=#{self.height}&file=#{self.url}&width=#{self.width}&height=#{self.height}&image=#{self.clipping.url(:screenshot)}" />)
  end
  
  def embed_js
    return nil unless self.encoding?
  	%(
  	<div id="flash_container_#{self.key[0..4]}"><a href="http://www.macromedia.com/go/getflashplayer">Get the latest Flash Player</a> to watch this video.</div>
  	<script type="text/javascript">
      var flashvars = {};
      
      flashvars.file = "#{self.url}";
      flashvars.image = "#{self.clipping.url(:screenshot)}";
      flashvars.width = "#{self.width}";
      flashvars.height = "#{self.height}";
      flashvars.fullscreen = "true";
      flashvars.controlbar = "over";
      var params = {wmode:"transparent",allowfullscreen:"true"};
      var attributes = {};
      attributes.align = "top";
      swfobject.embedSWF("#{Store.url('player.swf')}", "flash_container_#{self.key[0..4]}", "#{self.width}", "#{self.height}", "9.0.115", "#{Store.url('expressInstall.swf')}", flashvars, params, attributes);
  	</script>
  	)
	end
  
  # Interaction with store
  # ======================
  
  def upload_to_store
    Store.set(self.filename, self.tmp_filepath)
  end
  
  def fetch_from_store
    Store.get(self.filename, self.tmp_filepath)
  end
  
  # Deletes the video file without raising an exception if the file does 
  # not exist.
  def delete_from_store
    Store.delete(self.filename)
    self.clippings.each { |c| c.delete_from_store }
    Store.delete(self.clipping.filename(:screenshot, :default => true))
    Store.delete(self.clipping.filename(:thumbnail, :default => true))
  rescue AbstractStore::FileDoesNotExistError
    false
  end
  
  # Returns configured number of 'middle points', for example [25,50,75]
  def thumbnail_percentages
    n = Panda::Config[:choose_thumbnail]
    
    return [50] if n == false
    
    # Interval length
    interval = 100.0 / (n + 1)
    # Points is [0,25,50,75,100] for example
    points = (0..(n + 1)).map { |p| p * interval }.map { |p| p.to_i }
    
    # Don't include the end points
    return points[1..-2]
  end
  
  def generate_thumbnail_selection
    self.thumbnail_percentages.each do |percentage|
      self.clipping(percentage).capture
      self.clipping(percentage).resize
    end
  end
  
  def upload_thumbnail_selection
    self.thumbnail_percentages.each do |percentage|
      self.clipping(percentage).upload_to_store
      self.clipping(percentage).delete_locally
    end
  end
  
  # Checks that video can accept new file, checks that the video is valid, 
  # reads some metadata from it, and moves video into a private tmp location.
  # 
  # File is the tempfile object supplied by merb. It looks like
  # {
  #   "content_type"=>"video/mp4", 
  #   "size"=>100, 
  #   "tempfile" => @tempfile, 
  #   "filename" => "file.mov"
  # }
  # 
  def initial_processing(file)
    raise NoFileSubmitted if !file || file.blank?
    raise NotValid unless self.empty?
    
    # Set filename and original filename
    self.filename = self.key + File.extname(file[:filename])
    # Split out any directory path Windows adds in
    self.original_filename = file[:filename].split("\\").last
    
    # Move file into tmp location
    FileUtils.mv file[:tempfile].path, self.tmp_filepath
    
    self.read_metadata
    self.status = "original"
    self.save
  end
  
  # Uploads video to store, generates thumbnails if required, cleans up 
  # tempoary file, and adds encodings to the encoding queue.
  # 
  def finish_processing_and_queue_encodings
    self.upload_to_store
    
    # Generate thumbnails before we add to encoding queue
    self.generate_thumbnail_selection
    self.clipping(self.thumbnail_percentages.first).set_as_default
    self.upload_thumbnail_selection
    
    self.thumbnail_position = self.thumbnail_percentages.first
    self.save
    
    self.add_to_queue
    
    FileUtils.rm self.tmp_filepath
  end
  
  # Reads information about the video into attributes.
  # 
  # Raises FormatNotRecognised if the video is not valid
  # 
  def read_metadata
    Merb.logger.info "#{self.key}: Reading metadata of video file"
    
    inspector = RVideo::Inspector.new(:file => self.tmp_filepath, :ffmpeg_binary => $FFMPEG)
    
    raise FormatNotRecognised unless inspector.valid? and inspector.video?
    
    self.duration = (inspector.duration rescue nil)
    self.container = (inspector.container rescue nil)
    self.width = (inspector.width rescue nil)
    self.height = (inspector.height rescue nil)
    
    self.video_codec = (inspector.video_codec rescue nil)
    self.video_bitrate = (inspector.bitrate rescue nil)
    self.fps = (inspector.fps rescue nil)
    
    self.audio_codec = (inspector.audio_codec rescue nil)
    self.audio_sample_rate = (inspector.audio_sample_rate rescue nil)
    
    # Don't allow videos with a duration of 0
    raise FormatNotRecognised if self.duration == 0
  end
  
  def create_encoding_for_profile(p)
    encoding = Video.new
    encoding.status = 'queued'
    encoding.filename = "#{encoding.key}.#{p.container}"
    
    # Attrs from the parent video
    encoding.parent = self.key
    [:original_filename, :duration].each do |k|
      encoding.send("#{k}=", self.get(k))
    end
    
    # Attrs from the profile
    encoding.profile = p.key
    encoding.profile_title = p.title
    [:container, :width, :height, :video_codec, :video_bitrate, :fps, :audio_codec, :audio_bitrate, :audio_sample_rate, :player].each do |k|
      encoding.send("#{k}=", p.get(k))
    end
    
    encoding.save
    return encoding
  end
  
  # TODO: Breakout Profile adding into a different method
  def add_to_queue
    # Die if there's no profiles!
    if Profile.query.empty?
      Merb.logger.error "There are no encoding profiles!"
      return nil
    end
    
    # TODO: Allow manual selection of encoding profiles used in both form and api
    # For now we will just encode to all available profiles
    Profile.query.each do |p|
      if self.find_encoding_for_profile(p).empty?
        self.create_encoding_for_profile(p)
      end
    end
    return true
  end
  
  # API
  # ===
  
  # Hash of paramenters for video and encodings when video.xml/yaml requested.
  # 
  # See the specs for an example of what this returns
  # 
  def show_response
    # reload all encodings to ensure statuses are up to date!
    self.encodings.each{ |e| e.reload! }
    
    r = {
      :video => {
        :id => self.key,
        :status => self.status
      }
    }
    
    # Common attributes for originals and encodings
    if self.status == 'original' or self.encoding?
      [:filename, :original_filename, :width, :height, :duration].each do |k|
        r[:video][k] = self.send(k)
      end
    end

    # Only include the screenshot and thumbnail for the original video
    if self.status == 'original'
      r[:video][:screenshot]  = self.clipping.filename(:screenshot)
      r[:video][:thumbnail]   = self.clipping.filename(:thumbnail)
    
      # If the video is a parent, also return the data for all its encodings
      r[:video][:encodings] = self.encodings.map {|e| e.show_response}
    end
    
    # Return extra attributes if the video is an encoding
    if self.encoding?
      r[:video].merge! \
        [:parent, :profile, :profile_title, :encoded_at, :encoding_time].
          map_to_hash { |k| {k => self.send(k)} }
    end
    
    return r
  end
  
  def create_response
    {:video => {
        :id => self.key
      }
    }
  end
  
  # Encoding
  # ========
  
  def ffmpeg_resolution_and_padding
    # Calculate resolution and any padding
    in_w = self.parent_video.width.to_f
    in_h = self.parent_video.height.to_f
    out_w = self.width.to_f
    out_h = self.height.to_f

    begin
      aspect = in_w / in_h
    rescue
      Merb.logger.error "Couldn't do w/h to caculate aspect. Just using the output resolution now."
      return %(-s #{self.width}x#{self.height})
    end

    height = (out_w / aspect.to_f).to_i
    height -= 1 if height % 2 == 1

    opts_string = %(-s #{self.width}x#{height} )

    # Crop top and bottom is the video is too tall, but add top and bottom bars if it's too wide (aspect wise)
    if height > out_h
      crop = ((height.to_f - out_h) / 2.0).to_i
      crop -= 1 if crop % 2 == 1
      opts_string += %(-croptop #{crop} -cropbottom #{crop})
    elsif height < out_h
      pad = ((out_h - height.to_f) / 2.0).to_i
      pad -= 1 if pad % 2 == 1
      opts_string += %(-padtop #{pad} -padbottom #{pad})
    end

    return opts_string
  end
  
  def ffmpeg_resolution_and_padding_no_cropping
    # Calculate resolution and any padding
    in_w = self.parent_video.width.to_f
    in_h = self.parent_video.height.to_f
    out_w = self.width.to_f
    out_h = self.height.to_f

    begin
      aspect = in_w / in_h
      aspect_inv = in_h / in_w
    rescue
      Merb.logger.error "Couldn't do w/h to caculate aspect. Just using the output resolution now."
      return %(-s #{self.width}x#{self.height} )
    end

    height = (out_w / aspect.to_f).to_i
    height -= 1 if height % 2 == 1

    opts_string = %(-s #{self.width}x#{height} )

    # Keep the video's original width if the height
    if height > out_h
      width = (out_h / aspect_inv.to_f).to_i
      width -= 1 if width % 2 == 1

      opts_string = %(-s #{width}x#{self.height} )
      self.width = width
      self.save
    # Otherwise letterbox it
    elsif height < out_h
      pad = ((out_h - height.to_f) / 2.0).to_i
      pad -= 1 if pad % 2 == 1
      opts_string += %(-padtop #{pad} -padbottom #{pad})
    end

    return opts_string
  end
  
  def recipe_options(input_file, output_file)
    {
      :input_file => input_file,
      :output_file => output_file,
      :container => self.container, 
      :video_codec => self.video_codec,
      :video_bitrate_in_bits => self.video_bitrate_in_bits.to_s, 
      :fps => self.fps,
      :audio_codec => self.audio_codec.to_s, 
      :audio_bitrate => self.audio_bitrate.to_s, 
      :audio_bitrate_in_bits => self.audio_bitrate_in_bits.to_s, 
      :audio_sample_rate => self.audio_sample_rate.to_s, 
      :resolution => self.resolution,
      :resolution_and_padding => self.ffmpeg_resolution_and_padding_no_cropping
    }
  end
  
  def encode_flv_flash
    Merb.logger.info "Encoding with encode_flv_flash"
    transcoder = RVideo::Transcoder.new
    recipe = "#{$FFMPEG} -i $input_file$ -ar 22050 -ab $audio_bitrate$k -f flv -b $video_bitrate_in_bits$ -r 24 $resolution_and_padding$ -y $output_file$"
    recipe += "\nflvtool2 -U $output_file$"
    transcoder.execute(recipe, self.recipe_options(self.parent_video.tmp_filepath, self.tmp_filepath))
  end
  
  def encode_mp4_aac_flash
    Merb.logger.info "Encoding with encode_mp4_aac_flash"
    transcoder = RVideo::Transcoder.new
    # Just the video without audio
    temp_video_output_file = "#{self.tmp_filepath}.temp.video.mp4"
    temp_audio_output_file = "#{self.tmp_filepath}.temp.audio.mp4"
    temp_audio_output_wav_file = "#{self.tmp_filepath}.temp.audio.wav"

    recipe = "#{$FFMPEG} -i $input_file$ -b $video_bitrate_in_bits$ -an -vcodec libx264 -rc_eq 'blurCplx^(1-qComp)' -qcomp 0.6 -qmin 10 -qmax 51 -qdiff 4 -coder 1 -flags +loop -cmp +chroma -partitions +parti4x4+partp8x8+partb8x8 -me hex -subq 5 -me_range 16 -g 250 -keyint_min 25 -sc_threshold 40 -i_qfactor 0.71 $resolution_and_padding$ -r 24 -threads 4 -y $output_file$"
    recipe_audio_extraction = "#{$FFMPEG} -i $input_file$ -ar 48000 -ac 2 -y $output_file$"

    transcoder.execute(recipe, self.recipe_options(self.parent_video.tmp_filepath, temp_video_output_file))
    
    Merb.logger.info "Video encoding done"
    unless self.parent_video.audio_codec.blank?
      # We have to use nero to encode the audio as ffmpeg doens't support HE-AAC yet
      transcoder.execute(recipe_audio_extraction, recipe_options(self.parent_video.tmp_filepath, temp_audio_output_wav_file))
      Merb.logger.info "Audio extraction done"

      # Convert to HE-AAC
      %x(neroAacEnc -br #{self.audio_bitrate_in_bits} -he -if #{temp_audio_output_wav_file} -of #{temp_audio_output_file})
      Merb.logger.info "Audio encoding done"

      # Squash the audio and video together
      # A bit of a hacker here, because on some EC2 instances it won't save to /mnt for some reason. In the long term we won't need MP4Box because newer ffmpeg versions include aac support.
      tmp_mp4box_filepath = "/tmp/#{self.filename}"
      FileUtils.rm(tmp_mp4box_filepath) if File.exists?(tmp_mp4box_filepath) # rm, otherwise we end up with multiple video streams when we encode a few times!!

      FileUtils.cd(Panda::Config[:private_tmp_path]) do #so any temp files get put in the right directory
        %x(MP4Box -add #{temp_video_output_file}#video #{tmp_mp4box_filepath})
        %x(MP4Box -add #{temp_audio_output_file}#audio #{tmp_mp4box_filepath})
        %x(MP4Box -inter 500 #{tmp_mp4box_filepath})
      end
      FileUtils.mv(tmp_mp4box_filepath, self.tmp_filepath)
      Merb.logger.info "Squashing done"
    else
      Merb.logger.info "This video does't have an audio stream"
      FileUtils.mv(temp_video_output_file, self.tmp_filepath)
    end
  end
  
  def encode_unknown_format
    Merb.logger.info "Encoding with encode_unknown_format"
    transcoder = RVideo::Transcoder.new
    recipe = "#{$FFMPEG} -i $input_file$ -f $container$ -vcodec $video_codec$ -b $video_bitrate_in_bits$ -ar $audio_sample_rate$ -ab $audio_bitrate$k -acodec $audio_codec$ -r 24 $resolution_and_padding$ -y $output_file$"
    Merb.logger.info "Unknown encoding format given but trying to encode anyway."
    transcoder.execute(recipe, recipe_options(self.parent_video.tmp_filepath, self.tmp_filepath))
  end
  
  def encode!
    raise "You can only encode encodings" unless self.encoding?
    
    begun_encoding = Time.now
    
    begin
      encoding = self
      parent_obj = self.parent_video
      Merb.logger.info "(#{Time.now.to_s}) Encoding #{self.key}"
    
      parent_obj.fetch_from_store

      if self.container == "flv" and self.player == "flash"
        self.encode_flv_flash
      elsif self.container == "mp4" and self.audio_codec == "aac" and self.player == "flash"
        self.encode_mp4_aac_flash
      else # Try straight ffmpeg encode
        self.encode_unknown_format
      end
      
      self.upload_to_store
      
      self.status = "success"
      self.encoded_at = Time.now
      self.encoding_time = (Time.now - begun_encoding).to_i
      self.save

      Merb.logger.info "Removing tmp video files"
      FileUtils.rm self.tmp_filepath
      FileUtils.rm parent_obj.tmp_filepath
      
      Merb.logger.info "Encoding successful"
    rescue Exception => e
      Merb.logger.info <<-EOT.gsub(/^\s+\|/, '')
        |Exception caught: #{e}
        |Backtrace:
        |#{e.backtrace.join("\n")}
      EOT

      self.status = "error"
      self.save
      
      if File.exists?(parent_obj.tmp_filepath)
        FileUtils.rm parent_obj.tmp_filepath
      end
      
      Merb.logger.error "Unable to transcode file #{self.key}: #{$!.class} - #{$!.message}"
        
      raise EncodingError
    end
  end

  def inspect
    attributes
    super
  end

  def ==(other)
    other.is_a?(Video) && key == other.key
  end

end
