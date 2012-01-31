EBApplication is a couple of things which allow you to implement the "Should this app move to Application folder?" dialog just by adding __one__ line of code. All that you have to do is replace your `main.m` file's conent with:
	
	#import "EBApplication.h"
	int main(int argc, char *argv[])
	{
	    return EBApplicationMain(argc, (const char **)argv);
	}
Yes, that's all!

#### Attention! This project is in progress, so no warranty there. #####

eric_bro @ 2012

