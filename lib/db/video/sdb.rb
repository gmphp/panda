module SdbModel
  module VideoBase
    class Base < SimpleRecord::Base
      has_ints :duration, :width, :height, :fps
      has_attributes :filename, :original_filename, :parent, :status, :container, :video_codec, :video_bitrate, :audio_codec, :audio_bitrate, :audio_sample_rate, :profile, :profile_title, :player, :encoding_time, :encoded_at, :notification, :thumbnail_position
      has_dates :queued_at, :started_encoding_at, :last_notification_at, :updated_at, :created_at
    end
  end
end