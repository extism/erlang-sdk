.PHONY: compile test shell example clean

export PATH := $(HOME)/otp/29.1.1/bin:$(PATH)

compile:
	rebar3 compile

test:
	rebar3 ct --verbose

shell:
	rebar3 shell

example: compile
	escript examples/count_vowels.escript "Hello, World!"

clean:
	rebar3 clean
	rm -rf _build
