#!/bin/bash
sudo /etc/init.d/mysqld restart
sudo /etc/init.d/supervisord restart
sudo /etc/init.d/nginx restart
