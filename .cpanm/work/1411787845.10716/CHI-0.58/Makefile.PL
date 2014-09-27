
use strict;
use warnings;



use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Unified cache handling interface",
  "AUTHOR" => "Jonathan Swartz <swartz\@pobox.com>",
  "BUILD_REQUIRES" => {},
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "CHI",
  "EXE_FILES" => [],
  "LICENSE" => "perl",
  "NAME" => "CHI",
  "PREREQ_PM" => {
    "Carp::Assert" => "0.20",
    "Data::UUID" => 0,
    "Digest::JHash" => 0,
    "Digest::MD5" => 0,
    "File::Spec" => "0.80",
    "Hash::MoreUtils" => 0,
    "JSON" => 0,
    "List::MoreUtils" => "0.13",
    "Log::Any" => "0.08",
    "Moo" => "1.003",
    "MooX::Types::MooseLike" => "0.23",
    "MooX::Types::MooseLike::Base" => 0,
    "MooX::Types::MooseLike::Numeric" => 0,
    "Storable" => 0,
    "String::RewritePrefix" => 0,
    "Task::Weaken" => 0,
    "Time::Duration" => "1.06",
    "Time::Duration::Parse" => "0.03",
    "Time::HiRes" => "1.30",
    "Try::Tiny" => "0.05"
  },
  "TEST_REQUIRES" => {
    "Date::Parse" => 0,
    "Test::Builder" => 0,
    "Test::Class" => 0,
    "Test::Deep" => 0,
    "Test::Exception" => 0,
    "Test::More" => 0,
    "Test::Warn" => 0
  },
  "VERSION" => "0.58",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  my $tr = delete $WriteMakefileArgs{TEST_REQUIRES};
  my $br = $WriteMakefileArgs{BUILD_REQUIRES};
  for my $mod ( keys %$tr ) {
    if ( exists $br->{$mod} ) {
      $br->{$mod} = $tr->{$mod} if $tr->{$mod} > $br->{$mod};
    }
    else {
      $br->{$mod} = $tr->{$mod};
    }
  }
}

unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



