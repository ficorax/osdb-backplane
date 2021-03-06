/*
 * UTILS/DHISTORY.E
 *
 * (c)Copyright 2000-2002 Backplane, Inc.  Please refer to the COPYRIGHT
 * file at the base of the distribution tree.
 *
 *	Dump the history of the specified database to stdout
 *
 * $Backplane: rdbms/utils/dhistory.e,v 1.6 2003/05/31 06:57:12 dillon Exp $
 */

#include "defs.h"
#include <ctype.h>
#include <sys/time.h>

database_t Db;
database_t DbI;
dbstamp_t FTs = 0;
int QuietOpt = 0;
int SchemaOnlyOpt = 0;
int TransOpt = 1;
int TableOpt = 1;
int AllTablesOpt = 1;
int DropTableOpt = 0;
int DumpError = 0;

static void DoDump(const char *tableSchema, int commentOnly);

static int UseGmt;

void
task_main(int ac, char **av)
{
    int i;
    int error;
    char *dataBase = NULL;
    char *useSchema;
    char *tsFile = NULL;
    dbstamp_t syncTs = 0;

    for (i = 1; i < ac; ++i) {
	char *ptr = av[i];

	if (*ptr == '@') {
	    FTs = ascii_to_dbstamp(ptr + 1);
	    continue;
	} 
	if (*ptr != '-') {
	    if (dataBase != NULL) {
		fprintf(stderr, "Unexpected argument: %s\n", ptr);
		exit(1);
	    }
	    dataBase = ptr;
	    continue;
	}
	ptr += 2;
	switch(ptr[-1]) {
	case 's':
	    SchemaOnlyOpt = 1;	/* only dump database schema */
	    break;
	case 'n':
	    TransOpt = 0;	/* do not generate begin/commit transactions */
	    break;
	case 'A':
	    AllTablesOpt = 0;	/* do not dump the sys table */
	    break;
	case 'd':
	    DropTableOpt = 1;	/* add DROP TABLE before CREATE */
	    break;
	case 'q':
	    QuietOpt = 1;
	    break;
	case 'D':
	    SetDefaultDBDir((*ptr) ? ptr : av[++i]);
	    break;
	case 'T':
	    tsFile = (*ptr) ? ptr : av[++i];
	    break;
	case 'G':
	    if (strcmp(ptr - 1, "GMT") == 0) {
		UseGmt = 1;
		break;
	    }
	    /* fall through */
	default:
	    fprintf(stderr, "Unknown option: %s\n", ptr - 2);
	    exit(1);
	}
    }
    if (dataBase == NULL) {
	fprintf(stderr, "Version 1.00\n");
	fprintf(stderr, "%s [@timestamp] [-Ansdq] [-T tsfile] [-D dbdir] [-q] [-GMT] dataBase[:schema.table]\n", av[0]);
	fprintf(stderr, "man rsql for timestamp format\n");
	exit(1);
    }
    if ((useSchema = strrchr(dataBase, ':')) != NULL)
	*useSchema++ = 0;

    Db = OpenCLDataBase(dataBase, &error);
    if (Db == NULL) {
	fprintf(stderr, "OpenCLDataBase() failed error %d\n", error);
	exit(1);
    }
    DbI = OpenCLInstance(Db, &syncTs, CLTYPE_RW);
    if (DbI == NULL) {
	fprintf(stderr, "OpenCLInstance() failed\n");
	exit(1);
    }

    if (FTs == 0 && tsFile) {
	int fd;

	if ((fd = open(tsFile, O_RDWR)) >= 0) {
	    (void)read(fd, &FTs, sizeof(FTs));
	    close(fd);
	}
    }

    if (FTs == 0)
	FTs = syncTs;

    if (FTs > syncTs) {
	char *alloc1 = NULL;
	char *alloc2 = NULL;
	fprintf(
	    stderr, 
	    "Requested as-of time (%s) is later\n"
	    "then the most recent commit (%s)\n",
	    dbstamp_to_ascii(FTs, UseGmt, &alloc1),
	    dbstamp_to_ascii(syncTs, UseGmt, &alloc2)
	);
	exit(1);
    }

    if (QuietOpt == 0) {
	char *alloc1 = NULL;
	fprintf(
	    stderr,
	    "Database history as of %016llx %s\n",
	    FTs,
	    dbstamp_to_ascii(FTs, UseGmt, &alloc1)
	);
	printf(
	    "# Database history as of %016llx %s\n",
	    FTs,
	    dbstamp_to_ascii(FTs, UseGmt, &alloc1)
	);
	safe_free(&alloc1);
    }

    if (useSchema) {
	DoDump(useSchema, 0);
    } else {
	int status;

	BEGIN(DbI, FTs, status) {
	    printf("#\n");
	    printf("# Dumping Schemas\n");
	    printf("#\n");
	    printf("BEGIN;\n");

	    SELECT t.SchemaName, t.TableFile
		FROM sys.schemas=t
		ORDER BY t.SchemaName;
	    {
		if (AllTablesOpt == 0 && strcmp(t.SchemaName, "sys") == 0)
		    printf("# ");
		printf("CREATE SCHEMA %s", t.SchemaName);
		if (strcmp(t.SchemaName, t.TableFile) != 0)
		    printf(" USING FILE \"%s\"", t.TableFile);
		printf(";\n");
	    }
	    printf("COMMIT;\n");
	    printf("\n");

	    SELECT t.SchemaName, t.TableName, t.TableVId, t.TableFile 
		FROM sys.tables=t
		ORDER BY t.SchemaName, t.TableName;
	    {
		char *buf;
		int commentOnly = 0;

		/*
		 * We do not dump deleted tables (can't form the select
		 * anyway)
		 */
		if (strncmp(t.TableName, "$DEL", 4) == 0)
		    continue;

		/*
		 * Normally we do not dump sys.tables, or sys.repgroup,
		 * and sys.schemas is already dealt with.
		 */
		if (AllTablesOpt == 0 && strcmp(t.SchemaName, "sys") == 0) {
		    if (strcmp(t.TableName, "schemas") == 0)
			commentOnly = 1;
		    if (strcmp(t.TableName, "tables") == 0)
			commentOnly = 1;
		    if (strcmp(t.TableName, "repgroup") == 0)
			commentOnly = 1;
		}
		safe_asprintf(&buf, "%s.%s", t.SchemaName, t.TableName);
		DoDump(buf, commentOnly);
		free(buf);
	    }
	    ROLLBACK;
	}
    }
    if (tsFile) {
	int fd;

	if ((fd = open(tsFile, O_RDWR|O_CREAT)) >= 0) {
	    (void)write(fd, &FTs, sizeof(FTs));
	    close(fd);
	}
    }
    CloseCLInstance(DbI);
    CloseCLDataBase(Db);
    if (DumpError)
	exit(1);
}

static void
DoDump(const char *tableSchema, int commentOnly)
{
    char *qry;
    char *comment = (commentOnly) ? "# " : "";
    res_t res;
    int rv;

    printf("# Dumping Schema %s\n", tableSchema);
    printf("#\n");

    PushCLTrans(DbI, FTs, CPF_READONLY);
    safe_asprintf(&qry, 
	"SELECT c.ColName, c.ColType, c.ColFlags, c.ColId"
	" FROM %s$cols=c ORDER BY c.ColId",
	tableSchema
    );
    res = QueryCLTrans(DbI, qry, &rv);
    if (rv < 0 && DumpError == 0) {
	const char *emsg = GetCLErrorDesc(rv);
	printf("# ERROR %d (%s) RUNNING QUERY \"%s\"\n", rv, emsg, qry);
	fprintf(stderr, "ERROR %d (%s) RUNNING QUERY \"%s\"\n", rv, emsg, qry);
	DumpError = rv;
    }
    safe_free(&qry);

    if (res) {
	const char **row;
	const char **field = NULL;
	int fcount = 0;

	if (TransOpt)
	    printf("%sBEGIN;\n", comment);

	if (DropTableOpt)
	    printf("%sDROP TABLE %s;\n", comment, tableSchema);

	printf("%sCREATE TABLE %s (\n", comment, tableSchema);
	row = ResFirstRow(res);

	while (row) {
	    const char *flags;

	    if (row[2] == NULL || strchr(row[2], 'D') == NULL) {
		if (fcount)
		    printf(",\n");
		field = realloc(field, (fcount + 1) * sizeof(char *));
		field[fcount++] = row[0];

		/*
		 * Output the type declaration for this column
		 */
		printf("%s    %s\t%s", comment, row[0], row[1]);
		for (flags = row[2]; flags && *flags; ++flags) {
		    switch(*flags) {
		    case 'K':
			printf(" PRIMARY KEY");
			break;
		    case 'N':
			printf(" NOT NULL");
			break;
		    case 'U':
			printf(" UNIQUE");
			break;
		    default:
			printf(" FLAG(%c)", *flags);
			break;
		    }
		}
	    }
	    row = ResNextRow(res);
	}
	if (fcount)
	    printf("\n");
	printf("%s);\n\n", comment);

	if (TransOpt)
	    printf("%sCOMMIT;\n", comment);

	if (SchemaOnlyOpt == 0) {
	    int i;
	    int transCount = 0;
	    res_t res2;
	    char *alloc = NULL;

	    safe_asprintf(&qry, "HISTORY __timestamp, __opcode, __userid");

	    for (i = 0; i < fcount; ++i)
		safe_appendf(&qry, ", %s", field[i]);
	    safe_appendf(&qry, " FROM %s", tableSchema);

	    /*
	     * Push a streaming transaction
	     */
	    PushCLTrans(DbI, FTs, CPF_READONLY|CPF_STREAM);
	    res2 = QueryCLTrans(DbI, qry, &rv);
	    if (rv < 0) {
		const char *emsg = GetCLErrorDesc(rv);
		printf("# ERROR %d (%s) EXECUTING QUERY \"%s\"\n", rv, emsg, qry);
		fprintf(stderr, "ERROR %d (%s) EXECUTING QUERY \"%s\"\n", rv, emsg, qry);
		DumpError = rv;
	    }
	    safe_free(&qry);

	    if (res2) {
		const char **row2;
		int *len2;

		if (TableOpt) {
		    printf("%sLOAD INSERT INTO %s (", comment, tableSchema);
		    printf(" __timestamp, __opcode, __userid");
		    for (i = 0; i < fcount; ++i)
			printf(", %s", field[i]);
		    printf(" ) {\n");
		}

		for (row2 = ResFirstRowL(res2, &len2); 
		     row2; 
		     row2 = ResNextRowL(res2, &len2)) {
		    if (TransOpt && transCount == 0)
			printf("%sBEGIN;\n", comment);
		    /*
		     * Generate comment describing operation
		     */
		    if (QuietOpt == 0) {
			dbstamp_t stamp = strtouq(row2[0], NULL, 16);
			const char *opcode = row2[1];
			int opflags = strtol(opcode, NULL, 16);

			switch(opflags & (RHF_DELETE|RHF_UPDATE|RHF_INSERT)) {
			case RHF_DELETE:
			    opcode = "DELETE";
			    break;
			case RHF_UPDATE:
			    opcode = "UPDATE";
			    break;
			case RHF_INSERT:
			    opcode = "INSERT";
			    break;
			default:
			    break;
			}

			printf("# TS=%s OPCODE=%s\n",
			    dbstamp_to_ascii(stamp, UseGmt, &alloc),
			    opcode
			);
		    }
		    /*
		     * Generate table load insert command
		     */
		    if (TableOpt == 0) {
			printf("%sINSERT INTO %s (", comment, tableSchema);
			printf(" __timestamp, __opcode, __userid");
			for (i = 0; i < fcount; ++i)
			    printf(", %s", field[i]);
			printf(" )");
		    } else {
			printf("%s", comment);
		    }
		    printf(" VALUES(");
		    printf(" 0x%s, 0x%s, 0x%s", row2[0], row2[1], row2[2]);
		    for (i = 0; i < fcount; ++i) {
			if (row2[i+3])
			    printf(", '%s'", DBMSEscape(row2[i+3], &alloc, len2[i+3]));
			else
			    printf(", NULL");
		    }
		    printf(");\n");
		    if (TransOpt && ++transCount == 100) {
			printf("%sCOMMIT;\n", comment);
			transCount = 0;
		    }
		}
		if ((rv = ResStreamingError(res2)) < 0) {
		    const char *emsg = GetCLErrorDesc(rv);
		    printf("# STREAMING ERROR IN DUMP %d (%s), ROLLING BACK\n",
			rv,
			emsg
		    );
		    fprintf(stderr,
			"# STREAMING ERROR IN DUMP %d (%s), ROLLING BACK\n",
			rv, emsg
		    );
		    if (TransOpt && transCount)
			printf("%sROLLBACK;\n", comment);
		    printf("%s}\n", comment);
		    if (DumpError == 0)
			DumpError = ResStreamingError(res2);
		} else {
		    if (TransOpt && transCount)
			printf("%sCOMMIT;\n", comment);
		    printf("%s}\n", comment);
		}
		FreeCLRes(res2);
	    }
	    AbortCLTrans(DbI);
	    safe_free(&alloc);
	}
	printf("\n");
	free(field);
	FreeCLRes(res);
    }
    AbortCLTrans(DbI);
}

