use inc::Module::Install;

name 'Time-Duration';
all_from 'Duration.pm';

build_requires('Test::Pod');
build_requires('Test::Pod::Coverage');

auto_install;
WriteAll;
