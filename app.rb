# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvatore Sanfilippo.

require_relative 'app_config'
require 'rubygems'
require 'hiredis'
require 'redis'
require_relative 'page'
require 'sinatra'
require 'json'
require 'digest/sha1'
require 'digest/md5'
require_relative 'comments'
require_relative 'pbkdf2'
require_relative 'mail'
require_relative 'about'
require 'openssl' if UseOpenSSL

Version = "0.11.0"

def setup_redis
    $r = Redis.new(:host => RedisHost, :port => RedisPort) if !$r
end

before do
    setup_redis
    H = Lamernews::HTMLGen.new if !defined?(H)
    if !defined?(Comments)
        Comments = RedisComments.new($r,"comment",proc{|c,level|
            c.sort {|a,b|
                ascore = compute_comment_score a
                bscore = compute_comment_score b
                if ascore == bscore
                    # If score is the same favor newer comments
                    b['ctime'].to_i <=> a['ctime'].to_i
                else
                    # If score is different order by score.
                    # FIXME: do something smarter favouring newest comments
                    # but only in the short time.
                    bscore <=> ascore
                end
            }
        })
    end
    $user = nil
    auth_user(request.cookies['auth'])
    increment_karma_if_needed if $user
end

get '/' do
  @title = "#{SiteName} - #{SiteDescription}"
  @news, @numitems = get_top_news
  erb :news
end

get '/rss' do
    content_type 'text/xml', :charset => 'utf-8'
    news,count = get_latest_news
    H.rss(:version => "2.0", "xmlns:atom" => "http://www.w3.org/2005/Atom") {
        H.channel {
            H.title {
                "#{SiteName}"
            } + " " +
            H.link {
                "#{SiteUrl}"
            } + " " +
            H.description {
                "Description pending"
            } + " " +
            news_list_to_rss(news)
        }
    }
end

get '/latest' do
    redirect '/latest/0'
end

get '/latest/:start' do
    start = params[:start].to_i
    @title = "Latest news - #{SiteName}"
    @paginate = {
        :get => Proc.new {|start,count|
            get_latest_news(start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => LatestNewsPerPage,
        :link => "/latest/$"
    }
    erb :latest
end

get '/saved/:start' do
    redirect "/login" if !$user
    start = params[:start].to_i
    @title = "Saved news - #{SiteName}"
    @paginate = {
        :get => Proc.new {|start,count|
            get_saved_news($user['id'],start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => SavedNewsPerPage,
        :link => "/saved/$"
    }
    erb :saved
end

get '/usernews/:username/:start' do
    start = params[:start].to_i
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user

    @page_title = "News posted by #{user['username']}"

    @title = "#{page_title} - #{SiteName}"
    @paginate = {
        :get => Proc.new {|start,count|
            get_posted_news(user['id'],start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => SavedNewsPerPage,
        :link => "/usernews/#{H.urlencode user['username']}/$"
    }
    erb :usernews
end

get '/usercomments/:username/:start' do
    start = params[:start].to_i
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user

    @title = "#{user['username']} comments - #{SiteName}"
    @paginate = {
        :get => Proc.new {|start,count|
            get_user_comments(user['id'],start,count)
        },
        :render => Proc.new {|comment|
            u = get_user_by_id(comment["user_id"]) || DeletedUser
            comment_to_html(comment,u)
        },
        :start => start,
        :perpage => UserCommentsPerPage,
        :link => "/usercomments/#{H.urlencode user['username']}/$"
    }
    erb :usercomments
end

get '/replies' do
    redirect "/login" if !$user
    comments,count = get_user_comments($user['id'],0,SubthreadsInRepliesPage)
    @title = "Your threads - #{SiteName}"
    $r.hset("user:#{$user['id']}","replies",0)
    @aux = comments.map{|c| render_comment_subthread(c)}
    erb :replies
end

get '/login' do
    @title = "Login - #{SiteName}"
    erb :login
end

get '/reset-password' do
    @title = "Reset Password - #{SiteName}"
    erb :reset_password
end

get '/reset-password-ok' do
    @title = "Reset link sent to your inbox"
    erb :reset_password_ok
end

get '/set-new-password' do
    redirect '/' if (!check_params "user","auth")
    @user = get_user_by_username(params[:user])
    erb :set_new_password
end

get '/submit' do
    redirect "/login" if !$user
    @title = "Submit a new story - #{SiteName}"
    erb :submit
end

get '/logout' do
    if $user and check_api_secret
        update_auth_token($user)
    end
    redirect "/"
end

get "/news/:news_id" do
    @news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !@news
    # Show the news text if it is a news without URL.
    if !news_domain(@news) and !@news["del"]
        c = {
            "body" => news_text(@news),
            "ctime" => @news["ctime"],
            "user_id" => @news["user_id"],
            "thread_id" => @news["id"],
            "topcomment" => true
        }
        user = get_user_by_id(@news["user_id"]) || DeletedUser
        @top_comment = H.topcomment {comment_to_html(c,user)}
    else
        @top_comment = ""
    end
    @title = "#{@news["title"]} - #{SiteName}"
    erb :show_news
end

get "/comment/:news_id/:comment_id" do
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"],params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    erb :comment
end

def render_comment_subthread(comment,sep="")
    H.div(:class => "singlecomment") {
        u = get_user_by_id(comment["user_id"]) || DeletedUser
        comment_to_html(comment,u,true)
    }+H.div(:class => "commentreplies") {
        sep+
        render_comments_for_news(comment['thread_id'],comment["id"].to_i)
    }
end

get "/reply/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"],params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = get_user_by_id(comment["user_id"]) || DeletedUser

    H.set_title "Reply to comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user)+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news["id"])+
            H.inputhidden(:name => "comment_id", :value => -1)+
            H.inputhidden(:name => "parent_id", :value => params["comment_id"])+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
            H.button(:name => "post_comment", :value => "Reply")
        }+H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/editcomment/:news_id/:comment_id" do
    redirect "/login" if !$user
    @news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !@news
    @comment = Comments.fetch(params["news_id"],params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !@comment
    @user = get_user_by_id(@comment["user_id"]) || DeletedUser
    halt(500,"Permission denied.") if $user['id'].to_i != @user['id'].to_i

    @title = "Edit comment - #{SiteName}"
    erb :editcomment
end

get "/editnews/:news_id" do
    redirect "/login" if !$user
    @news = get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !@news
    halt(500,"Permission denied.") if $user['id'].to_i != @news['user_id'].to_i and !user_is_admin?($user)

    if news_domain(@news)
        @text = ""
    else
        @text = news_text(@news)
        @news['url'] = ""
    end
    @title = "Edit news - #{SiteName}"
    erb :editnews
end

get "/user/:username" do
    @user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !@user
    @posted_news, @posted_comments = $r.pipelined {
        $r.zcard("user.posted:#{@user['id']}")
        $r.zcard("user.comments:#{@user['id']}")
    }
    @title = "#{@user['username']} - #{SiteName}"
    @owner = $user && ($user['id'].to_i == @user['id'].to_i)
    email = @user["email"] || ""
    @digest = Digest::MD5.hexdigest(email)
    erb :user
end

get '/recompute' do
    if $user and user_is_admin?($user)
        $r.zrange("news.cron",0,-1).each{|news_id|
            news = get_news_by_id(news_id)
            score = compute_news_score(news)
            rank = compute_news_rank(news)
            $r.hmset("news:#{news_id}",
                "score",score,
                "rank",rank)
            $r.zadd("news.top",rank,news_id)
        }
        H.page {
            H.p {"Done."}
        }
    else
        redirect "/"
    end
end

get '/admin' do
    redirect "/" if !$user || !user_is_admin?($user)
    H.set_title "Admin Section - #{SiteName}"
    erb :admin
end

get '/random' do
    counter = $r.get("news.count")
    random = 1 + rand(counter.to_i)

    if $r.exists("news:#{random}")
        redirect "/news/#{random}"
    else
        redirect "/news/#{counter}"
    end
end

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
def check_params *required
    required.each{|p|
        params[p].strip! if params[p] and params[p].is_a? String
        if !params[p] or (p.is_a? String and params[p].length == 0)
            return false
        end
    }
    true
end

def check_api_secret
    return false if !$user
    params["apisecret"] and (params["apisecret"] == $user["apisecret"])
end

################################################################################
# User and authentication
################################################################################

# Try to authenticate the user, if the credentials are ok we populate the
# $user global with the user information.
# Otherwise $user is set to nil, so you can test for authenticated user
# just with: if $user ...
#
# Return value: none, the function works by side effect.
def auth_user(auth)
    return if !auth
    id = $r.get("auth:#{auth}")
    return if !id
    user = $r.hgetall("user:#{id}")
    $user = user if user.length > 0
end

# In Lamer News users get karma visiting the site.
# Increment the user karma by KarmaIncrementAmount if the latest increment
# was performed more than KarmaIncrementInterval seconds ago.
#
# Return value: none.
#
# Notes: this function must be called only in the context of a logged in
#        user.
#
# Side effects: the user karma is incremented and the $user hash updated.
def increment_karma_if_needed
    if $user['karma_incr_time'].to_i < (Time.now.to_i-KarmaIncrementInterval)
        userkey = "user:#{$user['id']}"
        $r.hset(userkey,"karma_incr_time",Time.now.to_i)
        increment_user_karma_by($user['id'],KarmaIncrementAmount)
    end
end

# Increment the user karma by the specified amount and make sure to
# update $user to reflect the change if it is the same user id.
def increment_user_karma_by(user_id,increment)
    userkey = "user:#{user_id}"
    $r.hincrby(userkey,"karma",increment)
    if $user and ($user['id'].to_i == user_id.to_i)
        $user['karma'] = $user['karma'].to_i + increment
    end
end

# Return the specified user karma.
def get_user_karma(user_id)
    return $user['karma'].to_i if $user and (user_id.to_i == $user['id'].to_i)
    userkey = "user:#{user_id}"
    karma = $r.hget(userkey,"karma")
    karma ? karma.to_i : 0
end

# Return the hex representation of an unguessable 160 bit random number.
def get_rand
    rand = "";
    File.open("/dev/urandom").read(20).each_byte{|x| rand << sprintf("%02x",x)}
    rand
end

# Create a new user with the specified username/password
#
# Return value: the function returns two values, the first is the
#               auth token if the registration succeeded, otherwise
#               is nil. The second is the error message if the function
#               failed (detected testing the first return value).
def create_user(username,password)
    if $r.exists("username.to.id:#{username.downcase}")
        return nil, "Username is already taken, please try a different one."
    end
    if rate_limit_by_ip(3600*15,"create_user",request.ip)
        return nil, "Please wait some time before creating a new user."
    end
    id = $r.incr("users.count")
    auth_token = get_rand
    salt = get_rand
    $r.hmset("user:#{id}",
        "id",id,
        "username",username,
        "salt",salt,
        "password",hash_password(password,salt),
        "ctime",Time.now.to_i,
        "karma",UserInitialKarma,
        "about","",
        "email","",
        "auth",auth_token,
        "apisecret",get_rand,
        "flags","",
        "karma_incr_time",Time.new.to_i)
    $r.set("username.to.id:#{username.downcase}",id)
    $r.set("auth:#{auth_token}",id)

    # First user ever created (id = 1) is an admin
    $r.hmset("user:#{id}","flags","a") if id.to_i == 1
    return auth_token,nil
end

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
def update_auth_token(user)
    $r.del("auth:#{user['auth']}")
    new_auth_token = get_rand
    $r.hmset("user:#{user['id']}","auth",new_auth_token)
    $r.set("auth:#{new_auth_token}",user['id'])
    return new_auth_token
end

# Turn the password into an hashed one, using PBKDF2 with HMAC-SHA1
# and 160 bit output.
def hash_password(password,salt)
    p = PBKDF2.new do |p|
        p.iterations = PBKDF2Iterations
        p.password = password
        p.salt = salt
        p.key_length = 160/8
    end
    p.hex_string
end

# Return the user from the ID.
def get_user_by_id(id)
    $r.hgetall("user:#{id}")
end

# Return the user from the username.
def get_user_by_username(username)
    id = $r.get("username.to.id:#{username.downcase}")
    return nil if !id
    get_user_by_id(id)
end

# Check if the username/password pair identifies an user.
# If so the auth token and form secret are returned, otherwise nil is returned.
def check_user_credentials(username,password)
    user = get_user_by_username(username)
    return nil if !user
    hp = hash_password(password,user['salt'])
    (user['password'] == hp) ? [user['auth'],user['apisecret']] : nil
end

# Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
def submitted_recently
    allowed_to_post_in_seconds > 0
end

# Indicates when the user is allowed to submit another story after the last.
def allowed_to_post_in_seconds
    return 0 if user_is_admin?($user)
    $r.ttl("user:#{$user['id']}:submitted_recently")
end

# Add the specified set of flags to the user.
# Returns false on error (non existing user), otherwise true is returned.
#
# Current flags:
# 'a'   Administrator.
# 'k'   Karma source, can transfer more karma than owned.
# 'n'   Open links to new windows.
#
def user_add_flags(user_id,flags)
    user = get_user_by_id(user_id)
    return false if !user
    newflags = user['flags']
    flags.each_char{|flag|
        newflags << flag if not user_has_flags?(user,flag)
    }
    # Note: race condition here if somebody touched the same field
    # at the same time: very unlkely and not critical so not using WATCH.
    $r.hset("user:#{user['id']}","flags",newflags)
    true
end

# Check if the user has all the specified flags at the same time.
# Returns true or false.
def user_has_flags?(user,flags)
    flags.each_char {|flag|
        return false if not user['flags'].index(flag)
    }
    true
end

def user_is_admin?(user)
    user_has_flags?(user,"a")
end

def send_reset_password_email(user)
    return false if !MailRelay || !MailFrom
    aux = request.url.split("/")
    return false if aux.length < 3
    current_domain = aux[0]+"//"+aux[2]

    reset_link = "#{current_domain}/set-new-password?user=#{H.urlencode(user['username'])}&auth=#{H.urlencode(user['auth'])}"

    subject = "#{aux[2]} password reset"
    message = "You can reset your password here: #{reset_link}"
    return mail(MailRelay,MailFrom,user['email'],subject,message)
end

################################################################################
# News
################################################################################

# Fetch one or more (if an Array is passed) news from Redis by id.
# Note that we also load other informations about the news like
# the username of the poster and other informations needed to render
# the news into HTML.
#
# Doing this in a centralized way offers us the ability to exploit
# Redis pipelining.
def get_news_by_id(news_ids,opt={})
    result = []
    if !news_ids.is_a? Array
        opt[:single] = true
        news_ids = [news_ids]
    end
    news = $r.pipelined {
        news_ids.each{|nid|
            $r.hgetall("news:#{nid}")
        }
    }
    return [] if !news # Can happen only if news_ids is an empty array.

    # Remove empty elements
    news = news.select{|x| x.length > 0}
    if news.length == 0
        return opt[:single] ? nil : []
    end

    # Get all the news
    $r.pipelined {
        news.each{|n|
            # Adjust rank if too different from the real-time value.
            update_news_rank_if_needed(n) if opt[:update_rank]
            result << n
        }
    }

    # Get the associated users information
    usernames = $r.pipelined {
        result.each{|n|
            $r.hget("user:#{n["user_id"]}","username")
        }
    }
    result.each_with_index{|n,i|
        n["username"] = usernames[i]
    }

    # Load $User vote information if we are in the context of a
    # registered user.
    if $user
        votes = $r.pipelined {
            result.each{|n|
                $r.zscore("news.up:#{n["id"]}",$user["id"])
                $r.zscore("news.down:#{n["id"]}",$user["id"])
            }
        }
        result.each_with_index{|n,i|
            if votes[i*2]
                n["voted"] = :up
            elsif votes[(i*2)+1]
                n["voted"] = :down
            end
        }
    end

    # Return an array if we got an array as input, otherwise
    # the single element the caller requested.
    opt[:single] ? result[0] : result
end

# Vote the specified news in the context of a given user.
# type is either :up or :down
# 
# The function takes care of the following:
# 1) The vote is not duplicated.
# 2) That the karma is decreased from voting user, accordingly to vote type.
# 3) That the karma is transfered to the author of the post, if different.
# 4) That the news score is updaed.
#
# Return value: two return values are returned: rank,error
#
# If the fucntion is successful rank is not nil, and represents the news karma
# after the vote was registered. The error is set to nil.
#
# On error the returned karma is false, and error is a string describing the
# error that prevented the vote.
def vote_news(news_id,user_id,vote_type)
    # Fetch news and user
    user = ($user and $user["id"] == user_id) ? $user : get_user_by_id(user_id)
    news = get_news_by_id(news_id)
    return false,"No such news or user." if !news or !user

    # Now it's time to check if the user already voted that news, either
    # up or down. If so return now.
    if $r.zscore("news.up:#{news_id}",user_id) or
       $r.zscore("news.down:#{news_id}",user_id)
       return false,"Duplicated vote."
    end

    # Check if the user has enough karma to perform this operation
    if $user['id'] != news['user_id']
        if (vote_type == :up and
             (get_user_karma(user_id) < NewsUpvoteMinKarma)) or
           (vote_type == :down and
             (get_user_karma(user_id) < NewsDownvoteMinKarma))
            return false,"You don't have enough karma to vote #{vote_type}"
        end
    end

    # News was not already voted by that user. Add the vote.
    # Note that even if there is a race condition here and the user may be
    # voting from another device/API in the time between the ZSCORE check
    # and the zadd, this will not result in inconsistencies as we will just
    # update the vote time with ZADD.
    if $r.zadd("news.#{vote_type}:#{news_id}", Time.now.to_i, user_id)
        $r.hincrby("news:#{news_id}",vote_type,1)
    end
    $r.zadd("user.saved:#{user_id}", Time.now.to_i, news_id) if vote_type == :up

    # Compute the new values of score and karma, updating the news accordingly.
    score = compute_news_score(news)
    news["score"] = score
    rank = compute_news_rank(news)
    $r.hmset("news:#{news_id}",
        "score",score,
        "rank",rank)
    $r.zadd("news.top",rank,news_id)

    # Remove some karma to the user if needed, and transfer karma to the
    # news owner in the case of an upvote.
    if $user['id'] != news['user_id']
        if vote_type == :up
            increment_user_karma_by(user_id,-NewsUpvoteKarmaCost)
            increment_user_karma_by(news['user_id'],NewsUpvoteKarmaTransfered)
        else
            increment_user_karma_by(user_id,-NewsDownvoteKarmaCost)
        end
    end

    return rank,nil
end

# Given the news compute its score.
# No side effects.
def compute_news_score(news)
    upvotes = $r.zrange("news.up:#{news["id"]}",0,-1,:withscores => true)
    downvotes = $r.zrange("news.down:#{news["id"]}",0,-1,:withscores => true)
    # FIXME: For now we are doing a naive sum of votes, without time-based
    # filtering, nor IP filtering.
    # We could use just ZCARD here of course, but I'm using ZRANGE already
    # since this is what is needed in the long term for vote analysis.
    score = upvotes.length-downvotes.length
    # Now let's add the logarithm of the sum of all the votes, since
    # something with 5 up and 5 down is less interesting than something
    # with 50 up and 50 donw.
    votes = upvotes.length/2+downvotes.length/2
    if votes > NewsScoreLogStart
        score += Math.log(votes-NewsScoreLogStart)*NewsScoreLogBooster
    end
    score
end

# Given the news compute its rank, that is function of time and score.
#
# The general forumla is RANK = SCORE / (AGE ^ AGING_FACTOR)
def compute_news_rank(news)
    age = (Time.now.to_i - news["ctime"].to_i)
    rank = ((news["score"].to_f)*1000000)/((age+NewsAgePadding)**RankAgingFactor)
    rank = -age if (age > TopNewsAgeLimit)
    return rank
end

# Add a news with the specified url or text.
#
# If an url is passed but was already posted in the latest 48 hours the
# news is not inserted, and the ID of the old news with the same URL is
# returned.
#
# Return value: the ID of the inserted news, or the ID of the news with
# the same URL recently added.
def insert_news(title,url,text,user_id)
    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Check for already posted news with the same URL.
    if !textpost and (id = $r.get("url:"+url))
        return id.to_i
    end
    # We can finally insert the news.
    ctime = Time.new.to_i
    news_id = $r.incr("news.count")
    $r.hmset("news:#{news_id}",
        "id", news_id,
        "title", title,
        "url", url,
        "user_id", user_id,
        "ctime", ctime,
        "score", 0,
        "rank", 0,
        "up", 0,
        "down", 0,
        "comments", 0)
    # The posting user virtually upvoted the news posting it
    rank,error = vote_news(news_id,user_id,:up)
    # Add the news to the user submitted news
    $r.zadd("user.posted:#{user_id}",ctime,news_id)
    # Add the news into the chronological view
    $r.zadd("news.cron",ctime,news_id)
    # Add the news into the top view
    $r.zadd("news.top",rank,news_id)
    # Add the news url for some time to avoid reposts in short time
    $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
    # Set a timeout indicating when the user may post again
    $r.setex("user:#{$user['id']}:submitted_recently",NewsSubmissionBreak,'1')
    return news_id
end

# Edit an already existing news.
#
# On success the news_id is returned.
# On success but when a news deletion is performed (empty title) -1 is returned.
# On failure (for instance news_id does not exist or does not match
#             the specified user_id) false is returned.
def edit_news(news_id,title,url,text,user_id)
    news = get_news_by_id(news_id)
    return false if !news or news['user_id'].to_i != user_id.to_i and !user_is_admin?($user)
    return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime)) and !user_is_admin?($user)

    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Even for edits don't allow to change the URL to the one of a
    # recently posted news.
    if !textpost and url != news['url']
        return false if $r.get("url:"+url)
        # No problems with this new url, but the url changed
        # so we unblock the old one and set the block in the new one.
        # Otherwise it is easy to mount a DOS attack.
        $r.del("url:"+news['url'])
        $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
    end
    # Edit the news fields.
    $r.hmset("news:#{news_id}",
        "title", title,
        "url", url)
    return news_id
end

# Mark an existing news as removed.
def del_news(news_id,user_id)
    news = get_news_by_id(news_id)
    return false if !news or news['user_id'].to_i != user_id.to_i and !user_is_admin?($user)
    return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime)) and !user_is_admin?($user)

    $r.hmset("news:#{news_id}","del",1)
    $r.zrem("news.top",news_id)
    $r.zrem("news.cron",news_id)
    return true
end

# Return the host part of the news URL field.
# If the url is in the form text:// nil is returned.
def news_domain(news)
    su = news["url"].split("/")
    domain = (su[0] == "text:") ? nil : su[2]
end

# Assuming the news has an url in the form text:// returns the text
# inside. Otherwise nil is returned.
def news_text(news)
    su = news["url"].split("/")
    (su[0] == "text:") ? news["url"][7..-1] : nil
end

# Turn the news into its RSS representation
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
def news_to_rss(news)
    domain = news_domain(news)
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news["ln_url"] = "#{SiteUrl}/news/#{news["id"]}"
    news["url"] = news["ln_url"] if !domain

    H.item {
        H.title {
            H.entities news["title"]
        } + " " +
        H.guid {
            H.entities news["url"]
        } + " " +
        H.link {
            H.entities news["url"]
        } + " " +
        H.description {
            "<![CDATA[" +
            H.a(:href=>news["ln_url"]) {
                "Comments"
            } + "]]>"
        } + " " +
        H.comments {
            H.entities news["ln_url"]
        }
    }+"\n"
end


# Turn the news into its HTML representation, that is
# a linked title with buttons to up/down vote plus additional info.
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
def news_to_html(news)
    return H.article(:class => "deleted") {
        "[deleted news]"
    } if news["del"]
    domain = news_domain(news)
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news["url"] = "/news/#{news["id"]}" if !domain
    upclass = "uparrow"
    downclass = "downarrow"
    if news["voted"] == :up
        upclass << " voted"
        downclass << " disabled"
    elsif news["voted"] == :down
        downclass << " voted"
        upclass << " disabled"
    end
    H.article("data-news-id" => news["id"]) {
        H.a(:href => "#up", :class => upclass) {
            "&#9650;"
        }+" "+
        H.h2 {
            H.a(:href=>news["url"], :rel => "nofollow") {
                H.entities news["title"]
            }
        }+" "+
        H.address {
            if domain
                "at "+H.entities(domain)
            else "" end +
            if ($user and $user['id'].to_i == news['user_id'].to_i and
                news['ctime'].to_i > (Time.now.to_i - NewsEditTime))
                " " + H.a(:href => "/editnews/#{news["id"]}") {
                    "[edit]"
                }
            else "" end
        }+
        H.a(:href => "#down", :class =>  downclass) {
            "&#9660;"
        }+
        H.p {
            H.span(:class => :upvotes) { news["up"] } + " up and " +
            H.span(:class => :downvotes) { news["down"] } + " down, posted by " +            
            H.username {
                H.a(:href=>"/user/"+H.urlencode(news["username"])) {
                    H.entities news["username"]
                }
            }+" "+str_elapsed(news["ctime"].to_i)+" "+
            H.a(:href => "/news/#{news["id"]}") {
                comments_number = news["comments"].to_i
                if comments_number != 0
                    "#{news["comments"] + ' comment'}" + "#{'s' if comments_number>1}"
                else
                    "discuss"
                end
            }+
            if $user and user_is_admin?($user)
                " - "+H.a(:href => "/editnews/#{news["id"]}") { "edit" }+" - "+H.a(:href => "http://twitter.com/intent/tweet?url=#{SiteUrl}/news/#{news["id"]}&text="+H.urlencode(news["title"])+" - ") { "tweet" }
            else "" end
        }+
        if params and params[:debug] and $user and user_is_admin?($user)
            "id: "+news["id"].to_s+" "+
            "score: "+news["score"].to_s+" "+
            "rank: "+compute_news_rank(news).to_s+" "+
            "zset_rank: "+$r.zscore("news.top",news["id"]).to_s
        else "" end
    }+"\n"
end

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the RSS needed to show this news.
def news_list_to_rss(news)
    aux = ""
    news.each{|n|
        aux << news_to_rss(n)
    }
    aux
end

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the HTML needed to show this news.
def news_list_to_html(news)
    H.section(:id => "newslist") {
        aux = ""
        news.each{|n|
            aux << news_to_html(n)
        }
        aux
    }
end

# Updating the rank would require some cron job and worker in theory as
# it is time dependent and we don't want to do any sorting operation at
# page view time. But instead what we do is to compute the rank from the
# score and update it in the sorted set only if there is some sensible error.
# This way ranks are updated incrementally and "live" at every page view
# only for the news where this makes sense, that is, top news.
#
# Note: this function can be called in the context of redis.pipelined {...}
def update_news_rank_if_needed(n)
    real_rank = compute_news_rank(n)
    delta_rank = (real_rank-n["rank"].to_f).abs
    if delta_rank > 0.000001
        $r.hmset("news:#{n["id"]}","rank",real_rank)
        $r.zadd("news.top",real_rank,n["id"])
        n["rank"] = real_rank.to_s
    end
end

# Generate the main page of the web site, the one where news are ordered by
# rank.
# 
# As a side effect thsi function take care of checking if the rank stored
# in the DB is no longer correct (as time is passing) and updates it if
# needed.
#
# This way we can completely avoid having a cron job adjusting our news
# score since this is done incrementally when there are pageviews on the
# site.
def get_top_news(start=0,count=TopNewsPerPage)
    numitems = $r.zcard("news.top")
    news_ids = $r.zrevrange("news.top",start,start+(count-1))
    result = get_news_by_id(news_ids,:update_rank => true)
    # Sort by rank before returning, since we adjusted ranks during iteration.
    return result.sort{|a,b| b["rank"].to_f <=> a["rank"].to_f},numitems
end

# Get news in chronological order.
def get_latest_news(start=0,count=LatestNewsPerPage)
    numitems = $r.zcard("news.cron")
    news_ids = $r.zrevrange("news.cron",start,start+(count-1))
    return get_news_by_id(news_ids,:update_rank => true),numitems
end

# Get saved news of current user
def get_saved_news(user_id,start,count)
    numitems = $r.zcard("user.saved:#{user_id}").to_i
    news_ids = $r.zrevrange("user.saved:#{user_id}",start,start+(count-1))
    return get_news_by_id(news_ids),numitems
end

# Get news posted by the specified user
def get_posted_news(user_id,start,count)
    numitems = $r.zcard("user.posted:#{user_id}").to_i
    news_ids = $r.zrevrange("user.posted:#{user_id}",start,start+(count-1))
    return get_news_by_id(news_ids),numitems
end

###############################################################################
# Comments
###############################################################################

# This function has different behaviors, depending on the arguments:
#
# 1) If comment_id is -1 insert a new comment into the specified news.
# 2) If comment_id is an already existing comment in the context of the
#    specified news, updates the comment.
# 3) If comment_id is an already existing comment in the context of the
#    specified news, but the comment is an empty string, delete the comment.
#
# Return value:
#
# If news_id does not exist or comment_id is not -1 but neither a valid
# comment for that news, nil is returned.
# Otherwise an hash is returned with the following fields:
#   news_id: the news id
#   comment_id: the updated comment id, or the new comment id
#   op: the operation performed: "insert", "update", or "delete"
#
# More informations:
#
# The parent_id is only used for inserts (when comment_id == -1), otherwise
# is ignored.
def insert_comment(news_id,user_id,comment_id,parent_id,body)
    news = get_news_by_id(news_id)
    return false if !news
    if comment_id == -1
        if parent_id.to_i != -1
            p = Comments.fetch(news_id,parent_id)
            return false if !p
        end
        comment = {"score" => 0,
                   "body" => body,
                   "parent_id" => parent_id,
                   "user_id" => user_id,
                   "ctime" => Time.now.to_i,
                   "up" => [user_id.to_i] };
        comment_id = Comments.insert(news_id,comment)
        return false if !comment_id
        $r.hincrby("news:#{news_id}","comments",1);
        $r.zadd("user.comments:#{user_id}",
            Time.now.to_i,
            news_id.to_s+"-"+comment_id.to_s);
        # increment_user_karma_by(user_id,KarmaIncrementComment)
        if p and $r.exists("user:#{p['user_id']}")
            $r.hincrby("user:#{p['user_id']}","replies",1)
        end
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "insert"
        }
    end

    # If we reached this point the next step is either to update or
    # delete the comment. So we make sure the user_id of the request
    # matches the user_id of the comment.
    # We also make sure the user is in time for an edit operation.
    c = Comments.fetch(news_id,comment_id)
    return false if !c or c['user_id'].to_i != user_id.to_i
    return false if !(c['ctime'].to_i > (Time.now.to_i - CommentEditTime))

    if body.length == 0
        return false if !Comments.del_comment(news_id,comment_id)
        $r.hincrby("news:#{news_id}","comments",-1);
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "delete"
        }
    else
        update = {"body" => body}
        update = {"del" => 0} if c['del'].to_i == 1
        return false if !Comments.edit(news_id,comment_id,update)
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "update"
        }
    end
end

# Compute the comment score
def compute_comment_score(c)
    upcount = (c['up'] ? c['up'].length : 0)
    downcount = (c['down'] ? c['down'].length : 0)
    upcount-downcount
end

# Given a string returns the same string with all the urls converted into
# HTML links. We try to handle the case of an url that is followed by a period
# Like in "I suggest http://google.com." excluding the final dot from the link.
def urls_to_links(s)
    urls = /((https?:\/\/|www\.)([-\w\.]+)+(:\d+)?(\/([\w\/_#:\.\-\%]*(\?\S+)?)?)?)/
    s.gsub(urls) {
        url = text = $1
        url = "http://#{url}" if $2 == 'www.'
        if $1[-1..-1] == '.'
            url = url.chop
            text = text.chop
            '<a rel="nofollow" href="'+url+'">'+text+'</a>.'
        else
            '<a rel="nofollow" href="'+url+'">'+text+'</a>'
        end
    }
end

# Render a comment into HTML.
# 'c' is the comment representation as a Ruby hash.
# 'u' is the user, obtained from the user_id by the caller.
# 'show_parent' flag to show link to parent comment.
def comment_to_html(c,u,show_parent = false)
    indent = "margin-left:#{c['level'].to_i*CommentReplyShift}px"
    score = compute_comment_score(c)
    news_id = c['thread_id']

    if c['del'] and c['del'].to_i == 1
        return H.article(:style => indent,:class=>"commented deleted") {
            "[comment deleted]"
        }
    end
    show_edit_link = !c['topcomment'] &&
                ($user && ($user['id'].to_i == c['user_id'].to_i)) &&
                (c['ctime'].to_i > (Time.now.to_i - CommentEditTime))

    comment_id = "#{news_id}-#{c['id']}"
    H.article(:class => "comment", :style => indent,
              "data-comment-id" => comment_id, :id => comment_id) {
        H.span(:class => "avatar") {
            email = u["email"] || ""
            digest = Digest::MD5.hexdigest(email)
            H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
        }+H.span(:class => "info") {
            H.span(:class => "username") {
                H.a(:href=>"/user/"+H.urlencode(u["username"])) {
                    H.entities u["username"]
                }
            }+" "+str_elapsed(c["ctime"].to_i)+". "+
            if !c['topcomment']
                H.a(:href=>"/comment/#{news_id}/#{c["id"]}", :class=>"reply") {
                    "link"
                }+" "
            else "" end +
            if show_parent && c["parent_id"] > -1
                H.a(:href=>"/comment/#{news_id}/#{c["parent_id"]}", :class=>"reply") {
                    "parent"
                }+" "
            else "" end +
            if $user and !c['topcomment']
                H.a(:href=>"/reply/#{news_id}/#{c["id"]}", :class=>"reply") {
                    "reply"
                }+" "
            else " " end +
            if !c['topcomment']
                upclass = "uparrow"
                downclass = "downarrow"
                if $user and c['up'] and c['up'].index($user['id'].to_i)
                    upclass << " voted"
                    downclass << " disabled"
                elsif $user and c['down'] and c['down'].index($user['id'].to_i)
                    downclass << " voted"
                    upclass << " disabled"
                end
                "#{score} point"+"#{'s' if score.to_i.abs>1}"+" "+
                H.a(:href => "#up", :class => upclass) {
                    "&#9650;"
                }+" "+
                H.a(:href => "#down", :class => downclass) {
                    "&#9660;"
                }
            else " " end +
            if show_edit_link
                H.a(:href=> "/editcomment/#{news_id}/#{c["id"]}",
                    :class =>"reply") {"edit"}+
                    " (#{
                        (CommentEditTime - (Time.now.to_i-c['ctime'].to_i))/60
                    } minutes left)"
            else "" end
        }+H.pre {
            urls_to_links H.entities(c["body"].strip)
        }
    }
end

def render_comments_for_news(news_id,root=-1)
    html = ""
    user = {}
    Comments.render_comments(news_id,root) {|c|
        user[c["id"]] = get_user_by_id(c["user_id"]) if !user[c["id"]]
        user[c["id"]] = DeletedUser if !user[c["id"]]
        u = user[c["id"]]
        html << comment_to_html(c,u)
    }
    H.div("id" => "comments") {html}
end

def vote_comment(news_id,comment_id,user_id,vote_type)
    user_id = user_id.to_i
    comment = Comments.fetch(news_id,comment_id)
    return false if !comment
    varray = (comment[vote_type.to_s] or [])
    return false if varray.index(user_id)
    varray << user_id
    return Comments.edit(news_id,comment_id,{vote_type.to_s => varray})
end

# Get comments in chronological order for the specified user in the
# specified range.
def get_user_comments(user_id,start,count)
    numitems = $r.zcard("user.comments:#{user_id}").to_i
    ids = $r.zrevrange("user.comments:#{user_id}",start,start+(count-1))
    comments = []
    ids.each{|id|
        news_id,comment_id = id.split('-')
        comment = Comments.fetch(news_id,comment_id)
        comments << comment if comment
    }
    [comments,numitems]
end

###############################################################################
# Admin section & stats
###############################################################################

def generate_site_stats
    H.ul {
        H.li {"#{$r.get("users.count")} users"} +
        H.li {"#{$r.zcard("news.cron")} news posted"} +
        H.li {"#{$r.info['used_memory_human']} of used memory"}
    }
end

###############################################################################
# Utility functions
###############################################################################

# Given an unix time in the past returns a string stating how much time
# has elapsed from the specified time, in the form "2 hours ago".
def str_elapsed(t)
    seconds = Time.now.to_i - t
    return "now" if seconds <= 1

    length,label = time_lengths.select{|length,label| seconds >= length }.first
    units = seconds/length
    "#{units} #{label}#{'s' if units > 1} ago"
end

def time_lengths
    [[86400, "day"], [3600, "hour"], [60, "minute"], [1, "second"]]
end

# Generic API limiting function
def rate_limit_by_ip(delay,*tags)
    key = "limit:"+tags.join(".")
    return true if $r.exists(key)
    $r.setex(key,delay,1)
    return false
end

# Show list of items with show-more style pagination.
#
# The function sole argument is an hash with the following fields:
#
# :get     A function accepinng start/count that will return two values:
#          1) A list of elements to paginate.
#          2) The total amount of items of this type.
#
# :render  A function that given an element obtained with :get will turn
#          in into a suitable representation (usually HTML).
#
# :start   The current start (probably obtained from URL).
#
# :perpage Number of items to show per page.
#
# :link    A string that is used to obtain the url of the [more] link
#          replacing '$' with the right value for the next page.
#
# Return value: the current page rendering.
def list_items(o)
    aux = ""
    o[:start] = 0 if o[:start] < 0
    items,count = o[:get].call(o[:start],o[:perpage])
    items.each{|n|
        aux << o[:render].call(n)
    }
    last_displayed = o[:start]+o[:perpage]
    if last_displayed < count
        nextpage = o[:link].sub("$",
                   (o[:start]+o[:perpage]).to_s)
        aux << H.a(:href => nextpage,:class=> "more") {"[more]"}
    end
    aux
end

def urlencode(s)
  CGI::escape(s)
end
