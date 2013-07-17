
module Lamernews

  ###############################################################################
  # Navigation, header and footer.
  ###############################################################################
  
  # Return the HTML for the 'replies' link in the main navigation bar.
  # The link is not shown at all if the user is not logged in, while
  # it is shown with a badge showing the number of replies for logged in
  # users.
  def self.navbar_replies_link
      return "" if !$user
      count = $user['replies'] || 0
      H.a(:href => "/replies", :class => "replies") {
          "replies"+
          if count.to_i > 0
              H.sup {count}
          else "" end
      }
  end
  
  def self.navbar_admin_link
      return "" if !$user || !user_is_admin?($user)
      H.b {
          H.a(:href => "/admin") {"admin"}
      }
  end

  def self.application_header
      navitems = [    ["top","/"],
                      ["latest","/latest/0"],
                      ["random","/random"],                    
                      ["submit","/submit"]]
      navbar = H.nav {
          navitems.map{|ni|
              H.a(:href=>ni[1]) {H.entities ni[0]}
          }.inject{|a,b| a+"\n"+b}+navbar_replies_link+navbar_admin_link
      }
      rnavbar = H.nav(:id => "account") {
          if $user
              H.a(:href => "/user/"+H.urlencode($user['username'])) { 
                  H.entities $user['username']+" (#{$user['karma']})"
              }+" | "+
              H.a(:href =>
                  "/logout?apisecret=#{$user['apisecret']}") {
                  "logout"
              }
          else
              H.a(:href => "/login") {"login / register"}
          end
      }
      menu_mobile = H.a(:href => "#", :id => "link-menu-mobile"){"<~>"}
      H.header {
          H.h1 {
              H.a(:href => "/") {H.entities SiteName}+" "+
              H.small {Version}
          }+navbar+" "+rnavbar+" "+menu_mobile
      }
  end
  
end
