include $(TOPDIR)/rules.mk

APP_TITLE:=ovpnctl
CLOSED_GPL_INSTALL:=y
APP_DEPENDS:=+libubus +libuci +lua +luasocket +openvpn-openssl

include ../api.mk

# call BuildPackage - OpenWrt buildroot signature
