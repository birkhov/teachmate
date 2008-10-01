class SubscriptionsController < ApplicationController

  validates_captcha

  before_filter :set_return_to, :except => [:create]
  before_filter :should_be_logged_in, :only => [:index]

  # When the request comes
  # 1. Check if the user is logged in.
  #   1) Check for search_query validity
  #     * redirect back if not valid
  #   2) Save subscription
  #   3) Redirect back to search results page
  # 2. If unllogged in
  #   1) Check for search_query validity
  #     * redirect back if not valid
  #   2) Show quick signup form
  #   3) Check if email and captcha are valid
  #   4) Save subscription
  #   5) Redirect back to search results page
  def create
    if request.post?

      @search_query = SearchQuery.new(params[:search_query])
      return unless validate_search_query # this redirects back to search request if false

      # Environment for quick_signup
      @subscription = Subscription.new
      @teach = @search_query.learn.join(', ')
      @learn = @search_query.teach.join(', ')
      
      if params[:user]
        return unless should_be_captcha_validated
        @user = User.new(:email => params[:user][:email])
        @user.errors.add(:email, "can't be blank") if @user.email.blank?
        if @user.errors.empty? and @user.save
          session[:user] = @user.id
          redirect_to_stored and return
        end
      end
      
      if current_logged_in
        @search_query.store_query
        @subscription = Subscription.create(:user_id => current_logged_in, :search_query_id => @search_query.id)
        if @subscription.valid?
          flash[:subscription_ok] = "Done. You will receive emails with updates for this search request daily."
        
        # This 'else' should definetely mean that such a subscription already exists
        else
          flash[:subscription_error] = "You've already subscribed to that request."
        end
        redirect_to_stored and return
      end

      render(:template => 'subscriptions/quick_signup')

    end
  end

  def index
    @subscriptions = Subscription.find_for_user(current_logged_in)
  end

  def destroy
    Subscription.delete(params[:id])
    flash[:message] = "The subscription was removed."
    redirect_to :back
  end

  private

  def should_be_captcha_validated
    unless captcha_validated?
      flash.now[:error] = "Sorry, the letters you entered don't match the ones on the picture, try again."
      render(:template => "subscriptions/quick_signup") and return(false)
    end
    return true
  end

  def validate_search_query
    unless @search_query.valid?
      flash[:subscription_error] = "Your search request is invalid. You can't subscribe to it."
      redirect_to_stored and return(false) # when it's false, caller 'returns' and breaks the create method
    end
    return true
  end

end
