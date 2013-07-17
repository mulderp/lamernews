module Lamernews
  def self.application_footer
      if $user
          apisecret = H.script() {
              "var apisecret = '#{$user['apisecret']}';";
          }
      else
          apisecret = ""
      end
      if KeyboardNavigation == 1
          keyboardnavigation = H.script() {
              "setKeyboardNavigation();"
          } + " " +
          H.div(:id => "keyboard-help", :style => "display: none;") {
              H.div(:class => "keyboard-help-banner banner-background banner") {
              } + " " +
              H.div(:class => "keyboard-help-banner banner-foreground banner") {
                  H.div(:class => "primary-message") {
                      "Keyboard shortcuts"
                  } + " " +
                  H.div(:class => "secondary-message") {
                      H.div(:class => "key") {
                          "j/k:"
                      } + H.div(:class => "desc") {
                          "next/previous item"
                      } + " " +
                      H.div(:class => "key") {
                          "enter:"
                      } + H.div(:class => "desc") {
                          "open link"
                      } + " " +
                      H.div(:class => "key") {
                          "a/z:"
                      } + H.div(:class => "desc") {
                          "up/down vote item"
                      }
                  }
              }
          }
      else
          keyboardnavigation = ""
      end
      H.footer {
          links = [
              ["about", "/about"],
              ["source code", "http://github.com/antirez/lamernews"],
              ["rss feed", "/rss"],
              ["twitter", FooterTwitterLink],
              ["google group", FooterGoogleGroupLink]
          ]
          links.map{|l| l[1] ?
              H.a(:href => l[1]) {H.entities l[0]} :
              nil
          }.select{|l| l}.join(" | ")
      }+apisecret+keyboardnavigation
  end
end
