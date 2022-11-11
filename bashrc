# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

# User specific environment
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]
then
    PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=

# User specific aliases and functions
if [ -d ~/.bashrc.d ]; then
	for rc in ~/.bashrc.d/*; do
		if [ -f "$rc" ]; then
			. "$rc"
		fi
	done
fi

#Coloring and set PS1
force_color_prompt=yes

#choose random color and title on terminal generation
randnum=$((1 + RANDOM % 4))

if [ $randnum == 1 ]; then PS1='\[\e]2;ᕙ(◕ل͜◕)ᕗ\a\]\[\033[1;35m\]\u\[\033[1;37m\]@\[\033[1;35m\]\h\[\033[00m\]:\[\033[1;35m\]\w\[\033[00m\]\$ '
elif [ $randnum == 2 ]; then PS1='\[\e]2;( ༎ຶ ෴ ༎ຶ)\a\]\[\033[1;36m\]\u\[\033[1;37m\]@\[\033[1;36m\]\h\[\033[00m\]:\[\033[1;36m\]\w\[\033[00m\]\$ '
elif [ $randnum == 3 ]; then PS1='\[\e]2;┻━┻︵ \(°□°)/ ︵ ┻━┻\a\]\[\033[1;34m\]\u\[\033[1;37m\]@\[\033[1;34m\]\h\[\033[00m\]:\[\033[1;34m\]\w\[\033[00m\]\$ '
elif [ $randnum == 4 ]; then PS1='\[\e]2;¯\_(ツ)_/¯\a\]\[\033[1;32m\]\u\[\033[1;37m\]@\[\033[1;32m\]\h\[\033[00m\]:\[\033[1;32m\]\w\[\033[00m\]\$ '
else echo 'Uh oh'
fi

#echo 'Welcome back, I love you <3'

unset rc
