package haxeon.ui.semantics;

/** Roles already understood by NativeKit's virtual accessibility tree. */
enum AccessibilityRole implements Hashable {
	Group;
	Button;
	Checkbox;
	Radio;
	Text;
	TextField;
	Link;
	Image;
	Heading;
	List;
	ListItem;
	Slider;
	ScrollArea;
	Dialog;
	Menu;
	MenuBar;
	MenuItem;
	TabList;
	Tab;
	TabPanel;
	Switch;
	ProgressBar;
	ComboBox;
	Collection;
	CollectionItem;
	Grid;
	Row;
	Cell;
	ColumnHeader;
	RowHeader;
	Tree;
	TreeItem;
	Separator;
	Toolbar;
	Status;
	Alert;
}
