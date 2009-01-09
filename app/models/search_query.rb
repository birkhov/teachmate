# For now it works like this:
# 1) You pass a joined tags string, the method splits it, then
# 2) finds all tags' ids (both learn and teach - then splits this arr into two:
# 	 @learn_tags & @teach_tags)
# 3) performs a number of queries which eventually find only those users who have all
# 	 of the given teach_tags and not just one
# 4) searches for users that contain both learn & teach tags' ids
# 5) searches for tags, that all found users have
class SearchQuery < ActiveRecord::Base

  has_many :subscriptions
	attr_reader :users, :learn_tags, :teach_tags, :learn, :teach, :city, :region, :country, :tags, :per_page

  validates_format_of :city,    :with => /\A[^,]+\Z/, :allow_blank => true
  validates_format_of :region,  :with => /\A[^,]+\Z/, :allow_blank => true
  validates_format_of :country, :with => /\A[^,]+\Z/, :allow_blank => true

	def per_page=(number)
		begin
			number = Integer(number)
			@per_page = number
			raise ArgumentError if number.nil? || number > 50 || number < 5
		rescue
			@per_page = 10
		end
	end

	def initialize(options)
		require 'taggable'

    #setting to null if empty?
    options.delete_if {|k,v| v.blank?}
    #downcasing
    options.each {|k,v| options[k]=v.chars.downcase if v.kind_of?(String)}

		@page = options[:page]
		self.per_page = options[:per_page]

    @city, @region, @country, @me = options[:city], options[:region], options[:country], options[:logged_in]
    @location = [@city, @region, @country].join(',')

		# Note, I switched teach/learn tags places. This is because
		# when someone searches for users, that she can teach 'bass guitar'
		# (i.e. 'bass guitar' is typed in I_can_teach field) they actually
		# search for someone who wants to learn bass guitar and have this in their
		# I_want_to_learn field.
		@learn = Taggable::ClassMethods.split_tags_string(options[:teach])
		@teach = Taggable::ClassMethods.split_tags_string(options[:learn])

    super()

    self.learn_string = @learn.sort.join(", ") unless @learn.blank?
    self.teach_string = @teach.sort.join(", ") unless @teach.blank?
    self.location     = @location
    
	end

	def run

    errors.add(:learn, "Too many tags") and return if @teach.length > 3
    errors.add(:teach, "Too many tags") and return if @learn.length > 100
    
    # searching and sorting all tags
    @teach_tags = @learn_tags = []
    unless @learn.empty? and @teach.empty?

      search_tags = Tag.find(:all, :include => [:learn_taggings],
      :conditions => ["string in (?)", (@learn+@teach)]) 

      @learn_tags, @teach_tags = search_tags.inject([[],[]]) do |pair, tag|
        pair[0] << tag if @learn.include?(tag.string)
        pair[1] << tag if @teach.include?(tag.string)
        pair
      end

      # If one of teach_tags is not found in the tag table, it means that
      # there's no such user with it and, therefore the search result
      # should be empty
      @users = [] and return if @teach_tags.length < @teach.length

      @learn_tags.uniq!
      @teach_tags.uniq!

    end

    # Setting parts of search request
    # (they'll be empty, if no corresponding options are passed in).
    placeholders = {}
    city_query_part     = ' AND city = :city'       and placeholders.merge!({:city => @city})       if @city
    region_query_part   = ' AND region = :region'   and placeholders.merge!({:region => @region})   if @region
    country_query_part  = ' AND country = :country' and placeholders.merge!({:country => @country}) if @country
    # Can't have excluding user id now, because of caching
    # me_query_part     = ' AND users.id != :id'    and placeholders.merge!({:id  => @me})          if @me
    me_query_part = ''
    location_query_part = "#{city_query_part}#{region_query_part}#{country_query_part}"


    # Here's where all SEARCH happens
    find_all(location_query_part, placeholders) if @learn.empty? and @teach.empty? #shows all users

    unless @teach_tags.empty?
      if learn_query_parts = find_teachers(location_query_part, placeholders)
        location_query_part       = learn_query_parts[:location_query_part]
        teach_taggings_condition  = learn_query_parts[:teach_taggings_condition]
      end
    end
    find_learners(location_query_part, placeholders, teach_taggings_condition) unless @learn_tags.empty?

    return if @users.blank? # Just exit if no users found

    user_ids = @users.map{ |u| u.id.to_s }.join(',')
    users_ids = @users.map {|u| u.id}
    teach_taggings = TeachTagging.find_by_sql(
      "SELECT tag_id FROM teach_taggings
      WHERE user_id in (#{users_ids.join(',')})"    
    ).map {|tagging| tagging.tag_id}
    learn_taggings = LearnTagging.find_by_sql(
      "SELECT tag_id FROM learn_taggings
      WHERE user_id in (#{users_ids.join(',')})"    
    ).map {|tagging| tagging.tag_id}

    taggings = (teach_taggings+learn_taggings).uniq

#     taggings = []
#     if RAILS_ENV == 'production'
#       No need remap results when using MySQL 
#     else
#       results.each { |i| taggings << i['teach_tag_id']; taggings << i['learn_tag_id'] }
#     end

    @tags = Tag.find(:all, :conditions => ["id in (:taggings)", {:taggings => taggings}])
    
    # Old way, slow query with 2 joins
    #
    # @tags = Tag.find(:all, :include => [:teach_taggings, :learn_taggings],
    #        :conditions => ["teach_taggings.user_id in (:users) OR 
    #        learn_taggings.user_id in (:users)", 
    #        {:users => @users}])

	end

  def store_query
    conditions = []
    conditions.push('learn_string = (:learn_string)') unless self.learn_string.blank?
    conditions.push('teach_string = (:teach_string)') unless self.teach_string.blank?
    conditions.push('location = (:location)') unless self.location.blank?

    if found_query = self.class.find(
      :first,
      :conditions => [conditions.join(' and '), {:learn_string => self.learn_string, :teach_string => self.teach_string, :location => self.location}]
    ) then
      self.id = found_query.id
    else
      self.save
    end
  end

  def after_find
    @city, @region, @country = self.location.split(',') if self.location and self.location != ',,'
		@learn = self.learn_string.split(", ") if self.learn_string
		@teach = self.teach_string.split(", ") if self.teach_string

    @learn = [] if @learn.nil?
    @teach = [] if @teach.nil?
  end


  private

  def find_all(location_query_part, placeholders)
    if NEW_FACES_SEARCH_INTERVAL
      users_created_at_query_part = ' AND users.created_at > :time_ago'
      placeholders.merge!({:time_ago => NEW_FACES_SEARCH_INTERVAL})
    end

    @users 	= User.paginate(:all,
      :page => @page, :per_page => @per_page,
      :conditions => 
      ["status IS NULL#{location_query_part}#{users_created_at_query_part}",
      {:teach_users => @teach_users, :learn_tags => @learn_tags}.merge!(placeholders)],
      :order => 'users.created_at DESC'
      )
  end

  def find_teachers(location_query_part, placeholders, me_query_part = nil)
    @teach_users = 
    @teach_tags.inject(nil) do |users, next_tag|

      if users.nil?: users_query_part = '' and users = [] # if running the first query
      elsif users.empty?: @users = [] and return  # if running n-th time and no users found in previous run
      else
        users_query_part = ' AND teach_taggings.user_id in (:users)'
        location_query_part = nil
      end

      find_params = {
        :include => [:teach_taggings],
        :conditions => ["teach_taggings.tag_id = :next_tag #{users_query_part}#{location_query_part}#{me_query_part}",
        {:next_tag => next_tag.id, :users => users}.merge!(placeholders)]
      }

      # Only paginate on request for the last teach_tag
      if @learn_tags.empty? and (@teach_tags.index(next_tag) == @teach_tags.length - 1)
        User.paginate(
          :all, 
          find_params.merge({:page => @page, :per_page => @per_page, :order => 'users.created_at DESC'})
        )
      else
        User.find(:all, find_params)
      end
    end

    @tags  = @teach_tags
    @users = @teach_users 
    {:teach_taggings_condition => "teach_taggings.user_id in (:teach_users) AND ",
    :location_query_part => nil}
  end

  def find_learners(location_query_part, placeholders, teach_taggings_condition)
    @users 	= User.paginate(:all,
            :page => @page, :per_page => @per_page,
            :include => [:teach_taggings, :learn_taggings],
            :conditions => 
            ["#{teach_taggings_condition}learn_taggings.tag_id in (:learn_tags)#{location_query_part}",
            {:teach_users => @teach_users, :learn_tags => @learn_tags}.merge!(placeholders)],
            :order => 'users.created_at DESC'
            )
    @tags = @learn_tags
  end

end
