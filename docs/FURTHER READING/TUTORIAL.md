# Learning Compos

The best way to think of compos is as a text editor that can run any application inside it. In order to do this, compos often 'translates' apps into compos so that it can offer
- a unified interface and
- access to the context for agents.

For one off tasks compos can easily just use the browser with a very capable browser use, but for repeatable and automated workflows, compos can create apps internally. You can use it just like you would n8n or zapier.

In order to provide such power to the user, Compos uses an Emacs style interface where you can say M-x (pronounced Meta-x, which is Alt+x) is the key that brings up the terminal. Typing autocompletes a command and then offers you the arguments to fill in. To test this, you should now type M-x and then type the words "load theme". You will see that the options keep narrowing as you type. Not just that, certain options have key combinations next to them. Pick an option enough and you can just use the keycombo next time you want it faster. It's also of course possible to create new keybindings on the fly. You don't need to remember anything. 

You configure Compos by talking to it. And you can even use a command palette with Cmd-p. 

## Chats

Chats are the fundamental