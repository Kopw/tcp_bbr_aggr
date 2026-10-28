obj-m := tcp_bbr_aggr.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD := $(shell pwd)

VERSION := 0.1.0
DKMS_SRC := /usr/src/tcp_bbr_aggr-$(VERSION)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# 用 DKMS 安装：内核升级后会自动重新编译
dkms:
	mkdir -p $(DKMS_SRC)
	cp -f Makefile dkms.conf tcp_bbr_aggr.c $(DKMS_SRC)/
	dkms add -m tcp_bbr_aggr -v $(VERSION) || true
	dkms build -m tcp_bbr_aggr -v $(VERSION)
	dkms install -m tcp_bbr_aggr -v $(VERSION) --force

dkms-remove:
	-modprobe -r tcp_bbr_aggr
	dkms remove -m tcp_bbr_aggr -v $(VERSION) --all
	rm -rf $(DKMS_SRC)

.PHONY: all clean dkms dkms-remove
